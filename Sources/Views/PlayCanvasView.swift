import SwiftUI

/// Renders the current touch's run lines, passes, rollball and (while playing) the ball,
/// and captures Run / Pass / Erase gestures.
struct PlayCanvasView: View {
    @ObservedObject var store: PlayStore
    let areaSize: CGSize   // shared with the tokens so coordinates match exactly

    // Run drawing
    @State private var runPlayer: UUID? = nil
    @State private var runPoints: [CGPoint] = []      // view coords
    @State private var runExtend = false              // extending an existing run vs new
    // Pass drawing
    @State private var passFrom: (id: UUID, point: CGPoint, t: CGFloat)? = nil
    @State private var passCurrent: CGPoint? = nil    // view coords
    // Pass editing (dragging an existing pass endpoint)
    @State private var editing: (id: UUID, end: PassEnd)? = nil
    @State private var editPoint: CGPoint? = nil      // view coords
    // Live snap target while drawing/editing a pass (view coords + which player).
    @State private var snap: (point: CGPoint, id: UUID)? = nil

    var body: some View {
        let size = areaSize
        return Canvas { ctx, _ in
                let t = store.displayTouch
                let animating = store.isAnimating || store.isRendering
                let runAlpha = animating ? 0.28 : 1.0
                let passAlpha = animating ? 0.75 : 1.0   // keep passes clearly visible in playback

                // Run lines — dashed while off the ball, solid while carrying it. Iterate all
                // players so a sub running out of the box (benched at the start) is drawn too.
                for p in store.roster {
                    guard let run = t.runs[p.id], run.points.count > 1 else { continue }
                    drawSegmentedRun(id: p.id, points: run.points, team: p.team,
                                     alpha: runAlpha, touch: t, ctx: &ctx, size: size)
                }
                // Passes.
                for pass in t.passes {
                    let color = store.player(pass.from)?.team.color ?? .white
                    drawPass(pass, color: color.opacity(passAlpha), ctx: &ctx, size: size)
                }
                // Catch (ring) and pass (diamond) markers on each run.
                for p in store.roster {
                    guard let run = t.runs[p.id], run.points.count > 1 else { continue }
                    let ev = store.ballEvents(p.id, in: t)
                    if let c = ev.catchAt {
                        drawCatchMarker(at: denorm(Geo.pointAlong(run.points, c), size),
                                        alpha: runAlpha, ctx: &ctx)
                    }
                    if let pa = ev.passAt {
                        drawPassMarker(at: denorm(Geo.pointAlong(run.points, pa), size),
                                       alpha: runAlpha, ctx: &ctx)
                    }
                }
                // Rollball marker (where this touch ended).
                if let rb = t.rollballAt {
                    drawRollball(at: denorm(rb, size), ctx: &ctx)
                }
                // Start-of-touch marker: tap, or the play-the-ball ruck.
                switch t.start {
                case .tap:
                    if let c = t.starts[t.carrier] {
                        drawStartMarker(anchor: denorm(c, size), isTap: true, ctx: &ctx)
                    }
                case .playTheBall:
                    if let m = t.startMark {
                        drawStartMarker(anchor: denorm(m, size), isTap: false, ctx: &ctx)
                    }
                }
                // Draggable handles on each pass endpoint while the Pass tool is active.
                if store.tool == .pass && !animating {
                    for pass in t.passes {
                        drawHandle(at: denorm(pass.fromPoint, size), ctx: &ctx)
                        drawHandle(at: denorm(pass.toPoint, size), ctx: &ctx)
                    }
                }
                // Handle on each run's end while the Run tool is active (grab to extend).
                if store.tool == .run && !animating {
                    for p in store.roster {
                        guard let run = t.runs[p.id], run.points.count > 1,
                              let end = run.points.last else { continue }
                        drawHandle(at: denorm(end, size), ctx: &ctx)
                    }
                }

                // In-progress run preview (canvas extend, and token-drawn runs).
                if runPoints.count > 1, let id = runPlayer {
                    let color = store.player(id)?.team.color ?? .white
                    drawRun(runPoints.map { norm($0, size) }, color: color, ctx: &ctx, size: size)
                }
                if store.liveRunPoints.count > 1 {
                    let color = store.player(store.liveRunID ?? UUID())?.team.color ?? .white
                    drawRun(store.liveRunPoints, color: color, ctx: &ctx, size: size)
                }

                // In-progress / editing pass preview, with live snap feedback.
                let fixedEnd: CGPoint? = {
                    if let from = passFrom { return denorm(from.point, size) }
                    if let e = editing,
                       let pass = store.currentTouch.passes.first(where: { $0.id == e.id }) {
                        return denorm(e.end == .from ? pass.toPoint : pass.fromPoint, size)
                    }
                    return nil
                }()
                if let fixed = fixedEnd {
                    if let end = snap?.point ?? editPoint ?? passCurrent {
                        var path = Path(); path.move(to: fixed); path.addLine(to: end)
                        ctx.stroke(path, with: .color(.white.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    }
                    if let s = snap {
                        // Highlight the player it will lodge on + mark the exact point.
                        let hp = denorm(store.displayPos(s.id), size)
                        ctx.stroke(Path(ellipseIn: CGRect(x: hp.x - 26, y: hp.y - 26, width: 52, height: 52)),
                                   with: .color(.yellow), style: StrokeStyle(lineWidth: 3))
                        ctx.fill(Path(ellipseIn: CGRect(x: s.point.x - 5, y: s.point.y - 5, width: 10, height: 10)),
                                 with: .color(.yellow))
                    }
                }
                // Animated ball — larger with a halo so it stands out against the grass.
                if animating {
                    let b = denorm(store.ballPos(), size)
                    let flight = store.ballFlight()
                    // Light trail behind the ball while it is passed, so the pass reads clearly.
                    if let flight {
                        let f0 = denorm(flight.from, size)
                        var line = Path(); line.move(to: f0); line.addLine(to: b)
                        ctx.stroke(line, with: .linearGradient(
                            Gradient(stops: [.init(color: .yellow.opacity(0), location: 0),
                                             .init(color: .yellow.opacity(0.32), location: 1)]),
                            startPoint: f0, endPoint: b),
                            style: StrokeStyle(lineWidth: 24, lineCap: .round))
                        ctx.stroke(line, with: .linearGradient(
                            Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                             .init(color: .yellow.opacity(0.95), location: 1)]),
                            startPoint: f0, endPoint: b),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    }
                    let inFlight = flight != nil
                    let hw: CGFloat = inFlight ? 30 : 19, hh: CGFloat = inFlight ? 24 : 15
                    ctx.fill(Path(ellipseIn: CGRect(x: b.x - hw, y: b.y - hh, width: hw * 2, height: hh * 2)),
                             with: .color(.yellow.opacity(inFlight ? 0.5 : 0.35)))
                    let rect = CGRect(x: b.x - 14, y: b.y - 9.5, width: 28, height: 19)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.64, green: 0.40, blue: 0.19)))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white), style: StrokeStyle(lineWidth: 2.5))
                    var lace = Path()
                    lace.move(to: CGPoint(x: b.x, y: b.y - 5)); lace.addLine(to: CGPoint(x: b.x, y: b.y + 5))
                    ctx.stroke(lace, with: .color(.white), style: StrokeStyle(lineWidth: 2))
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(gesture(size: size))
    }

    // MARK: Gestures

    private func gesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("play"))
            .onChanged { value in
                switch store.tool {
                case .run:
                    // New runs are drawn from the player tokens; the canvas only extends an
                    // existing run from its end handle.
                    if runPlayer == nil {
                        let n = norm(value.startLocation, size)
                        if let ext = nearestRunEnd(to: n) {
                            runPlayer = ext; runExtend = true; runPoints = [value.startLocation]
                        }
                    } else {
                        runPoints.append(value.location)
                    }
                case .pass:
                    if editing == nil && passFrom == nil {
                        // Grab an existing pass endpoint, else start a new pass.
                        if let handle = passHandle(at: norm(value.startLocation, size)) {
                            editing = handle
                        } else if let hit = nearestAnchor(to: norm(value.startLocation, size)) {
                            passFrom = (hit.id, hit.point, hit.t)
                        }
                    }
                    if editing != nil { editPoint = value.location }
                    else { passCurrent = value.location }
                    // Live snap feedback: where would this end lodge right now?
                    let exclude = editing != nil ? otherEndPlayer(editing!) : passFrom?.id
                    if (editing != nil || passFrom != nil),
                       let hit = nearestAnchor(to: norm(value.location, size), excluding: exclude) {
                        snap = (denorm(hit.point, size), hit.id)
                    } else {
                        snap = nil
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                let n = norm(value.location, size)
                switch store.tool {
                case .run:
                    if let id = runPlayer, runPoints.count > 1 {
                        let pts = runPoints.map { norm($0, size) }
                        if runExtend { store.appendRun(id, points: pts) }
                        else { store.setRun(id, points: pts) }
                    }
                    runPlayer = nil; runPoints = []; runExtend = false
                case .pass:
                    if let e = editing {
                        // Re-anchor the grabbed end to the nearest player's run line.
                        if let hit = nearestAnchor(to: n, excluding: otherEndPlayer(e)) {
                            store.updatePass(id: e.id, end: e.end,
                                             player: hit.id, point: hit.point, t: hit.t)
                        }
                    } else if let from = passFrom, let to = nearestAnchor(to: n, excluding: from.id) {
                        store.addPass(Pass(from: from.id, to: to.id,
                                           fromPoint: from.point, toPoint: to.point,
                                           fromT: from.t, toT: to.t))
                    }
                    passFrom = nil; passCurrent = nil
                    editing = nil; editPoint = nil; snap = nil
                case .erase:
                    store.eraseNearest(to: n)
                default:
                    break
                }
            }
    }

    /// Nearest on-field player anchor to a normalised point: a point on their run line,
    /// or their start if they have no run. `onlyStarts` restricts to start positions.
    private func nearestAnchor(to p: CGPoint, excluding: UUID? = nil, onlyStarts: Bool = false)
        -> (id: UUID, point: CGPoint, t: CGFloat)? {
        var best: (id: UUID, point: CGPoint, t: CGFloat, dist: CGFloat)? = nil
        let threshold: CGFloat = 0.06
        // On-field players, plus any player with a run (a sub running out of the box), so you
        // can pass to/from a sub as they come on.
        for player in store.roster where player.id != excluding
            && (!store.isBenched(player.id, in: store.currentIndex)
                || store.currentTouch.runs[player.id] != nil) {
            let start = store.startPos(player.id)
            if !onlyStarts, let run = store.currentTouch.runs[player.id], run.points.count > 1 {
                let n = Geo.nearestOnPolyline(p, run.points)
                if n.dist <= threshold && (best == nil || n.dist < best!.dist) {
                    best = (player.id, n.point, n.t, n.dist)
                }
            } else {
                let d = Geo.dist(p, start)
                if d <= threshold && (best == nil || d < best!.dist) {
                    best = (player.id, start, 0, d)
                }
            }
        }
        guard let b = best else { return nil }
        return (b.id, b.point, b.t)
    }

    /// If a point is near the end of any player's run, returns that player (to extend it).
    private func nearestRunEnd(to p: CGPoint) -> UUID? {
        let threshold: CGFloat = 0.05
        var best: (id: UUID, dist: CGFloat)? = nil
        for player in store.roster {
            guard let run = store.currentTouch.runs[player.id], let end = run.points.last else { continue }
            let d = Geo.dist(p, end)
            if d <= threshold && (best == nil || d < best!.dist) { best = (player.id, d) }
        }
        return best?.id
    }

    /// If a point is on an existing pass endpoint, returns which pass/end to edit.
    private func passHandle(at p: CGPoint) -> (id: UUID, end: PassEnd)? {
        let threshold: CGFloat = 0.045
        var best: (id: UUID, end: PassEnd, dist: CGFloat)? = nil
        for pass in store.currentTouch.passes {
            let df = Geo.dist(p, pass.fromPoint)
            if df <= threshold && (best == nil || df < best!.dist) { best = (pass.id, .from, df) }
            let dt = Geo.dist(p, pass.toPoint)
            if dt <= threshold && (best == nil || dt < best!.dist) { best = (pass.id, .to, dt) }
        }
        guard let b = best else { return nil }
        return (b.id, b.end)
    }

    /// The player on the end of a pass NOT being edited (so re-anchoring can exclude it).
    private func otherEndPlayer(_ e: (id: UUID, end: PassEnd)) -> UUID? {
        guard let pass = store.currentTouch.passes.first(where: { $0.id == e.id }) else { return nil }
        return e.end == .from ? pass.to : pass.from
    }

    private func drawHandle(at p: CGPoint, ctx: inout GraphicsContext) {
        let r: CGFloat = 7
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: rect), with: .color(.white))
        ctx.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.55)),
                   style: StrokeStyle(lineWidth: 1.5))
    }

    // MARK: Drawing

    /// Draws a run split into off-the-ball (dashed) and with-ball (solid) segments.
    private func drawSegmentedRun(id: UUID, points: [CGPoint], team: Team, alpha: Double,
                                  touch: Touch, ctx: inout GraphicsContext, size: CGSize) {
        let color = team.color.opacity(alpha)
        let solid = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        let dashed = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [2, 7])

        func stroke(_ seg: [CGPoint], _ style: StrokeStyle) {
            guard seg.count > 1 else { return }
            let d = seg.map { denorm($0, size) }
            var path = Path(); path.move(to: d[0])
            for pt in d.dropFirst() { path.addLine(to: pt) }
            ctx.stroke(path, with: .color(color), style: style)
        }

        if let hold = store.holdInterval(id, in: touch) {
            if hold.start > 0.001 { stroke(Geo.subPath(points, from: 0, to: hold.start), dashed) }
            stroke(Geo.subPath(points, from: hold.start, to: hold.end), solid)
            if hold.end < 0.999 { stroke(Geo.subPath(points, from: hold.end, to: 1), dashed) }
        } else {
            stroke(points, dashed)   // support / decoy run — never holds the ball
        }

        let d = points.map { denorm($0, size) }
        arrowHead(from: d[d.count - 2], to: d[d.count - 1], color: color, ctx: &ctx)
    }

    /// Catch marker — a hollow ring where a player receives the ball.
    private func drawCatchMarker(at p: CGPoint, alpha: Double, ctx: inout GraphicsContext) {
        let r: CGFloat = 6
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white.opacity(alpha)), style: StrokeStyle(lineWidth: 2.5))
    }

    /// Pass marker — a solid diamond where a player releases the ball.
    private func drawPassMarker(at p: CGPoint, alpha: Double, ctx: inout GraphicsContext) {
        let s: CGFloat = 6
        var d = Path()
        d.move(to: CGPoint(x: p.x, y: p.y - s))
        d.addLine(to: CGPoint(x: p.x + s, y: p.y))
        d.addLine(to: CGPoint(x: p.x, y: p.y + s))
        d.addLine(to: CGPoint(x: p.x - s, y: p.y))
        d.closeSubpath()
        ctx.fill(d, with: .color(.white.opacity(alpha)))
    }

    private func drawRun(_ pts: [CGPoint], color: Color, ctx: inout GraphicsContext, size: CGSize) {
        let d = pts.map { denorm($0, size) }
        guard d.count > 1 else { return }
        var path = Path()
        path.move(to: d[0])
        for p in d.dropFirst() { path.addLine(to: p) }
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        arrowHead(from: d[d.count - 2], to: d[d.count - 1], color: color, ctx: &ctx)
    }

    private func drawPass(_ pass: Pass, color: Color, ctx: inout GraphicsContext, size: CGSize) {
        let a = denorm(pass.fromPoint, size), b = denorm(pass.toPoint, size)
        var path = Path()
        path.move(to: a); path.addLine(to: b)
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [11, 6]))
        arrowHead(from: a, to: b, color: color, ctx: &ctx)
        // Origin dot.
        ctx.fill(Path(ellipseIn: CGRect(x: a.x - 3.5, y: a.y - 3.5, width: 7, height: 7)),
                 with: .color(color))
    }

    private func drawRollball(at p: CGPoint, ctx: inout GraphicsContext) {
        let r: CGFloat = 9
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white), style: StrokeStyle(lineWidth: 3))
        var bar = Path()
        bar.move(to: CGPoint(x: p.x - r - 5, y: p.y + r + 3))
        bar.addLine(to: CGPoint(x: p.x + r + 5, y: p.y + r + 3))
        ctx.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    /// Marker for how a touch starts, drawn just below the anchor so the player token
    /// (which sits on top) doesn't hide it.
    private func drawStartMarker(anchor: CGPoint, isTap: Bool, ctx: inout GraphicsContext) {
        let p = CGPoint(x: anchor.x, y: anchor.y + 30)
        let r: CGFloat = 8
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.white), style: StrokeStyle(lineWidth: 3))
        if isTap {
            // Foot tapping the ball.
            var tick = Path()
            tick.move(to: CGPoint(x: p.x - r - 6, y: p.y + r + 5))
            tick.addLine(to: CGPoint(x: p.x - 1, y: p.y + 1))
            ctx.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        } else {
            // Ground bar (ball rolled back under the foot).
            var bar = Path()
            bar.move(to: CGPoint(x: p.x - r - 5, y: p.y + r + 3))
            bar.addLine(to: CGPoint(x: p.x + r + 5, y: p.y + r + 3))
            ctx.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        let label = Text(isTap ? "tap" : "play the ball")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
        ctx.draw(label, at: CGPoint(x: p.x, y: p.y + r + 13), anchor: .top)
    }

    private func arrowHead(from: CGPoint, to: CGPoint, color: Color, ctx: inout GraphicsContext) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 14, spread = CGFloat.pi / 7
        let p1 = CGPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread))
        let p2 = CGPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread))
        var head = Path()
        head.move(to: to); head.addLine(to: p1)
        head.move(to: to); head.addLine(to: p2)
        ctx.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }

    // MARK: Coordinates

    private func norm(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: s.width == 0 ? 0 : p.x / s.width, y: s.height == 0 ? 0 : p.y / s.height)
    }
    private func denorm(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: p.x * s.width, y: p.y * s.height)
    }
}
