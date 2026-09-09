import SwiftUI
import Combine

// MARK: - Team

enum Team: String, Codable, CaseIterable, Identifiable {
    case attack
    case defence

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .attack: return Color(red: 0.90, green: 0.30, blue: 0.16)   // orange-red
        case .defence: return Color(red: 0.16, green: 0.45, blue: 0.85)  // blue
        }
    }

    var label: String { self == .attack ? "Attack" : "Defence" }
}

// MARK: - Positions

/// The three on-field positions in touch football (two of each per side).
enum Position: String, Codable, CaseIterable {
    case middle, link, wing
    var letter: String {
        switch self {
        case .middle: return "M"
        case .link: return "L"
        case .wing: return "W"
        }
    }
}

// MARK: - Player (identity only; field positions live per-touch)

struct Player: Identifiable, Codable {
    let id: UUID
    var team: Team
    var position: Position
    var isSub: Bool
    /// Stable number within this team's players of the same position (1–2 start on the
    /// field, 3–4 are the subs), so labels like M1/M3 track a player even when subbed on.
    var number: Int

    init(id: UUID = UUID(), team: Team, position: Position, isSub: Bool, number: Int = 1) {
        self.id = id
        self.team = team
        self.position = position
        self.isSub = isSub
        self.number = number
    }

    /// Token label, e.g. "M1", "L2", "W3".
    var label: String { "\(position.letter)\(number)" }
}

// MARK: - Play elements

struct RunLine: Codable {
    var points: [CGPoint]   // normalised; [0] = start, last = end
}

struct Pass: Codable, Identifiable {
    let id: UUID
    var from: UUID
    var to: UUID
    var fromPoint: CGPoint
    var toPoint: CGPoint
    var fromT: CGFloat      // progress along passer's run line
    var toT: CGFloat        // progress along receiver's run line

    init(id: UUID = UUID(), from: UUID, to: UUID,
         fromPoint: CGPoint, toPoint: CGPoint, fromT: CGFloat, toT: CGFloat) {
        self.id = id; self.from = from; self.to = to
        self.fromPoint = fromPoint; self.toPoint = toPoint
        self.fromT = fromT; self.toT = toT
    }
}

/// How a touch begins. A set always starts with a tap or a play-the-ball;
/// every touch after the first begins with a play-the-ball.
enum TouchStart: String, Codable {
    case tap
    case playTheBall
}

/// Where on the field a set begins.
enum StartPosition: String, Codable, CaseIterable, Identifiable {
    case own7m
    case halfway
    case attacking

    var id: String { rawValue }
    var label: String {
        switch self {
        case .own7m: return "Own 7m"
        case .halfway: return "Halfway"
        case .attacking: return "Attack"
        }
    }
    /// Fraction along the field length (attack attacks toward the far try line).
    var attackFx: CGFloat {
        switch self {
        case .own7m: return FieldLayout.tryLeft + FieldLayout.metresToFx(7)
        case .halfway: return FieldLayout.halfway
        case .attacking: return FieldLayout.tryRight - FieldLayout.metresToFx(20)
        }
    }
}

/// Which end of a pass is being edited.
enum PassEnd { case from, to }

struct Touch: Codable, Identifiable {
    let id: UUID
    var starts: [UUID: CGPoint]
    var runs: [UUID: RunLine]
    var passes: [Pass]
    var rollballAt: CGPoint?     // where THIS touch ended (the touch made)
    var carrier: UUID           // who has the ball at the start of the touch
    var start: TouchStart
    var startMark: CGPoint?      // ground location of the ruck (play-the-ball) start

    init(id: UUID = UUID(), starts: [UUID: CGPoint], carrier: UUID,
         start: TouchStart, startMark: CGPoint? = nil) {
        self.id = id
        self.starts = starts
        self.runs = [:]
        self.passes = []
        self.rollballAt = nil
        self.carrier = carrier
        self.start = start
        self.startMark = startMark
    }
}

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case position, run, pass, ball, erase
    var id: String { rawValue }

    var title: String {
        switch self {
        case .position: return "Move"
        case .run: return "Run"
        case .pass: return "Pass"
        case .ball: return "Ball"
        case .erase: return "Erase"
        }
    }
    var systemImage: String {
        switch self {
        case .position: return "hand.draw"
        case .run: return "scribble.variable"
        case .pass: return "arrow.up.right"
        case .ball: return "circle.circle"
        case .erase: return "eraser"
        }
    }
}

// MARK: - Store

final class PlayStore: ObservableObject {
    static let maxTouches = 6

    @Published private(set) var roster: [Player] = []
    @Published var touches: [Touch] = []
    @Published var currentIndex: Int = 0
    @Published var tool: Tool = .position
    @Published var debug: String = "ready"   // on-screen diagnostic for device testing
    @Published private(set) var startPosition: StartPosition = .halfway

    // Animation state (single source of truth for on-screen positions).
    @Published private(set) var isAnimating = false
    @Published private(set) var animIndex: Int = 0
    @Published private(set) var animU: CGFloat = 0

    private var timer: Timer?
    private var scope: [Int] = []
    private var scopePos = 0
    private var elapsed: TimeInterval = 0
    private var lastTick: Date?
    private let touchDuration: TimeInterval = 3.0
    private var transitioning = false
    private var transElapsed: TimeInterval = 0
    private let transitionDuration: TimeInterval = 0.6

    /// When set, rendering reflects this exact frame (used by the animation exporter).
    private var frameOverride: (index: Int, u: CGFloat, ball: CGPoint, flightFrom: CGPoint?)?
    var isRendering: Bool { frameOverride != nil }
    var animTouchDuration: TimeInterval { touchDuration }
    var animTransitionDuration: TimeInterval { transitionDuration }

    private var history: [(touches: [Touch], index: Int)] = []

    init() { resetAll() }

    // MARK: Roster & formation

    var currentTouch: Touch { touches[currentIndex] }
    /// The touch index shown right now (export frame > animation > current edit touch).
    var displayIndex: Int { frameOverride?.index ?? (isAnimating ? animIndex : currentIndex) }
    /// The touch whose lines should be drawn right now.
    var displayTouch: Touch { touches[displayIndex] }

    /// Whether a player is on a bench (i.e. subbed off) for a given touch. On/off is per
    /// touch: it is derived from where the player starts that touch, so a sub can come on or
    /// go off in one touch and (via carry-forward of start positions) stay that way after.
    func isBenched(_ id: UUID, in index: Int) -> Bool {
        guard index >= 0, index < touches.count, let p = touches[index].starts[id] else { return false }
        return FieldLayout.benchTop.contains(p) || FieldLayout.benchBottom.contains(p)
    }
    func onField(in index: Int) -> [Player] { roster.filter { !isBenched($0.id, in: index) } }
    /// On-field players for the touch shown right now (used by the views).
    var onFieldPlayers: [Player] { onField(in: displayIndex) }

    func player(_ id: UUID) -> Player? { roster.first { $0.id == id } }

    // Across-the-field order (sideline to sideline): W, L, M, M, L, W.
    private static let lineOrder: [Position] = [.wing, .link, .middle, .middle, .link, .wing]
    // Sub box order: two of each position.
    private static let subOrder: [Position] = [.middle, .middle, .link, .link, .wing, .wing]

    private func buildRoster() -> [Player] {
        var r: [Player] = []
        var counts: [String: Int] = [:]   // running number per team+position
        func add(_ team: Team, _ pos: Position, isSub: Bool) {
            let key = "\(team)-\(pos)"
            let n = (counts[key] ?? 0) + 1
            counts[key] = n
            r.append(Player(team: team, position: pos, isSub: isSub, number: n))
        }
        // On-field first (numbers 1–2), then subs (3–4), per team and position.
        for pos in Self.lineOrder { add(.attack, pos, isSub: false) }
        for pos in Self.lineOrder { add(.defence, pos, isSub: false) }
        for pos in Self.subOrder { add(.attack, pos, isSub: true) }
        for pos in Self.subOrder { add(.defence, pos, isSub: true) }
        return r
    }

    private func subPoint(_ box: CGRect, _ i: Int) -> CGPoint {
        CGPoint(x: box.minX + box.width * (CGFloat(i) + 0.5) / 6.0, y: box.midY)
    }

    /// Builds the starting formation for a given start type and field position:
    /// two middles stacked centrally (acting half + dummy half), links and wings fanning
    /// back in a flat V, and the defensive line a set distance in front
    /// (7 m off a play-the-ball, 10 m off a tap). Returns positions, ball carrier and the
    /// ruck/tap point (at the acting-half middle).
    private func formation(for start: TouchStart, at position: StartPosition)
        -> (starts: [UUID: CGPoint], carrier: UUID, mark: CGPoint) {
        var s: [UUID: CGPoint] = [:]
        let fx0 = position.attackFx
        let mid: CGFloat = 0.5

        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            let cfx = min(max(fx, FieldLayout.tryLeft + 0.01), FieldLayout.tryRight - 0.01)
            return FieldLayout.point(fx: cfx, fy: min(max(fy, 0.06), 0.94))
        }

        let attack = roster.filter { $0.team == .attack && !$0.isSub }
        let middles = attack.filter { $0.position == .middle }
        let links = attack.filter { $0.position == .link }
        let wings = attack.filter { $0.position == .wing }

        // Two middles stacked: M1 at the ruck (acting half), M2 (dummy half) behind.
        let m1 = middles[0]
        let m2 = middles.count > 1 ? middles[1] : middles[0]
        s[m1.id] = point(fx0, mid)
        s[m2.id] = point(fx0 - FieldLayout.metresToFx(5), mid)

        // Links then wings fan back and wide in a flat V.
        if links.count >= 2 {
            s[links[0].id] = point(fx0 - FieldLayout.metresToFx(4), mid - 0.20)
            s[links[1].id] = point(fx0 - FieldLayout.metresToFx(4), mid + 0.20)
        }
        if wings.count >= 2 {
            s[wings[0].id] = point(fx0 - FieldLayout.metresToFx(8), mid - 0.36)
            s[wings[1].id] = point(fx0 - FieldLayout.metresToFx(8), mid + 0.36)
        }

        // Defensive line, evenly spread across the width.
        let defDist: CGFloat = (start == .tap) ? 10 : 7
        let defFx = fx0 + FieldLayout.metresToFx(defDist)
        let defence = roster.filter { $0.team == .defence && !$0.isSub }
        for (i, p) in defence.enumerated() {
            s[p.id] = point(defFx, 0.14 + (0.86 - 0.14) * CGFloat(i) / 5.0)
        }

        // Subs on the benches.
        let aSubs = roster.filter { $0.team == .attack && $0.isSub }
        let dSubs = roster.filter { $0.team == .defence && $0.isSub }
        for (i, p) in aSubs.enumerated() { s[p.id] = subPoint(FieldLayout.benchBottom, i) }
        for (i, p) in dSubs.enumerated() { s[p.id] = subPoint(FieldLayout.benchTop, i) }

        // The acting-half middle taps; off a play-the-ball the dummy half picks up.
        let carrier = (start == .tap) ? m1.id : m2.id
        return (s, carrier, s[m1.id] ?? point(fx0, mid))
    }

    func resetAll() {
        stopAnimation()
        roster = buildRoster()
        applyStart(.tap, .halfway, resetHistory: true)
    }

    /// Builds a fresh single-touch set from the chosen start type and position.
    private func applyStart(_ start: TouchStart, _ position: StartPosition, resetHistory: Bool) {
        startPosition = position
        let f = formation(for: start, at: position)
        touches = [Touch(starts: f.starts, carrier: f.carrier, start: start, startMark: f.mark)]
        currentIndex = 0
        if resetHistory { history.removeAll() }
    }

    // MARK: Position queries

    func startPos(_ id: UUID, in index: Int? = nil) -> CGPoint {
        let t = touches[index ?? currentIndex]
        return t.starts[id] ?? CGPoint(x: 0.5, y: 0.9)
    }

    func endPos(_ id: UUID, in index: Int? = nil) -> CGPoint {
        let idx = index ?? currentIndex
        let t = touches[idx]
        if !isBenched(id, in: idx), let run = t.runs[id], let last = run.points.last { return last }
        return startPos(id, in: index)
    }

    /// Ease-in-out so runs accelerate and settle rather than starting/stopping abruptly.
    private func eased(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }
    private var animProgress: CGFloat { eased(animU) }

    /// Position to render right now — a specific frame while exporting, the live animation
    /// while playing, otherwise the edit start.
    func displayPos(_ id: UUID) -> CGPoint {
        if let o = frameOverride { return animatedPos(id, in: o.index, u: eased(o.u)) }
        if isAnimating { return animatedPos(id, in: animIndex, u: animProgress) }
        return startPos(id)
    }

    // MARK: Frame rendering (export)

    func setRenderFrame(index: Int, u: CGFloat, ball: CGPoint, flightFrom: CGPoint? = nil) {
        frameOverride = (index, u, ball, flightFrom)
        objectWillChange.send()
    }

    /// While the ball is mid-pass (or mid pickup between touches), the segment it is
    /// travelling along — used to draw a light trail so the pass stands out.
    func ballFlight() -> (from: CGPoint, head: CGPoint)? {
        if let o = frameOverride { return o.flightFrom.map { ($0, o.ball) } }
        if transitioning, scopePos + 1 < scope.count {
            return (endPos(finalCarrier(in: animIndex), in: animIndex), ballPos())
        }
        if let f = frameFlightFrom(index: animIndex, u: animU) { return (f, ballPos()) }
        return nil
    }

    /// The pass origin if `(index, u)` lands mid-flight, else nil (pure; for export frames).
    func frameFlightFrom(index: Int, u: CGFloat) -> CGPoint? {
        let uu = eased(u)
        let t = touches[index]
        let chain = passChain(t)
        let times = passTimes(chain.count)
        for (i, pass) in chain.enumerated() {
            let gi = times[i]
            if uu >= gi + passFlight { continue }
            if uu >= gi { return animatedPos(pass.from, in: index, u: uu) }
            break
        }
        return nil
    }
    func clearRenderFrame() {
        frameOverride = nil
        objectWillChange.send()
    }

    /// Ball position for an explicit touch/progress (used to build export frames).
    func frameBall(index: Int, u: CGFloat) -> CGPoint {
        let uu = eased(u)
        let t = touches[index]
        let chain = passChain(t)
        let times = passTimes(chain.count)
        var holder = t.carrier
        for (i, pass) in chain.enumerated() {
            let gi = times[i]
            if uu >= gi + passFlight {
                holder = pass.to
            } else if uu >= gi {
                let f = (uu - gi) / passFlight
                return Geo.lerp(animatedPos(pass.from, in: index, u: uu),
                                animatedPos(pass.to, in: index, u: uu), f)
            } else {
                break
            }
        }
        return animatedPos(holder, in: index, u: uu)
    }

    private let passFlight: CGFloat = 0.14   // fraction of the touch a pass is in the air

    /// Orders passes into the actual ball chain: carrier → receiver → next passer …
    func passChain(_ t: Touch) -> [Pass] {
        var chain: [Pass] = []
        var remaining = t.passes
        var holder = t.carrier
        while let idx = remaining.firstIndex(where: { $0.from == holder }) {
            let p = remaining.remove(at: idx)
            chain.append(p)
            holder = p.to
        }
        // Any passes not on the chain (drawn out of order) follow, by throw point.
        chain.append(contentsOf: remaining.sorted { $0.fromT < $1.fromT })
        return chain
    }

    /// Global time (0...1) of each pass in the chain, spread evenly across the touch.
    private func passTimes(_ count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return (0..<count).map { CGFloat($0 + 1) / CGFloat(count + 1) }
    }

    /// A player's progress along their run at global time `g`, honouring the moments they
    /// catch (at the pass's toT) and pass (at the pass's fromT). Segments the run in time:
    /// run without ball → catch → run with ball → pass → run without ball.
    private func timedProgress(_ id: UUID, in index: Int, at g: CGFloat) -> CGFloat {
        let t = touches[index]
        let chain = passChain(t)
        let times = passTimes(chain.count)
        var anchors: [(p: CGFloat, g: CGFloat)] = [(0, 0)]
        for (i, pass) in chain.enumerated() {
            if pass.to == id { anchors.append((pass.toT, times[i])) }    // catch
            if pass.from == id { anchors.append((pass.fromT, times[i])) } // pass
        }
        anchors.append((1, 1))
        anchors.sort { $0.g < $1.g }
        for i in 1..<anchors.count where anchors[i].p < anchors[i - 1].p {
            anchors[i].p = anchors[i - 1].p   // keep progress non-decreasing
        }
        if g <= 0 { return anchors.first!.p }
        for i in 1..<anchors.count where g <= anchors[i].g {
            let a = anchors[i - 1], b = anchors[i]
            let span = b.g - a.g
            return span <= 0 ? b.p : a.p + (b.p - a.p) * (g - a.g) / span
        }
        return anchors.last!.p
    }

    private func animatedPos(_ id: UUID, in index: Int, u: CGFloat) -> CGPoint {
        let t = touches[index]
        // A subbed-off player stays parked on the bench and never runs.
        if !isBenched(id, in: index), let run = t.runs[id], run.points.count > 1 {
            return Geo.pointAlong(run.points, timedProgress(id, in: index, at: u))
        }
        return t.starts[id] ?? CGPoint(x: 0.5, y: 0.9)
    }

    /// The run progress at which a player catches (receives a pass) and passes (throws), if any.
    func ballEvents(_ id: UUID, in t: Touch) -> (catchAt: CGFloat?, passAt: CGFloat?) {
        var catchAt: CGFloat? = nil
        var passAt: CGFloat? = nil
        for pass in t.passes {
            if pass.to == id { catchAt = pass.toT }
            if pass.from == id { passAt = pass.fromT }
        }
        return (catchAt, passAt)
    }

    /// The progress interval along a player's run during which they hold the ball
    /// (from catching / starting with it, to passing / being touched). Nil if never held.
    func holdInterval(_ id: UUID, in t: Touch) -> (start: CGFloat, end: CGFloat)? {
        var start: CGFloat? = (t.carrier == id) ? 0 : nil
        var end: CGFloat? = nil
        for pass in passChain(t) {
            if pass.to == id { start = pass.toT }
            if pass.from == id { end = pass.fromT }
        }
        guard let s = start else { return nil }
        return (s, end ?? 1)
    }

    /// Live ball position during animation.
    func ballPos() -> CGPoint {
        if let o = frameOverride { return o.ball }
        // Between touches: the ball is played and picked up by the dummy half — animate it
        // smoothly from the touched player at the ruck to the next touch's carrier.
        if transitioning, scopePos + 1 < scope.count {
            let nextIndex = scope[scopePos + 1]
            let from = endPos(finalCarrier(in: animIndex), in: animIndex)
            let to = startPos(touches[nextIndex].carrier, in: nextIndex)
            return Geo.lerp(from, to, eased(CGFloat(transElapsed / transitionDuration)))
        }
        let u = animProgress
        let t = touches[animIndex]
        let chain = passChain(t)
        let times = passTimes(chain.count)
        var holder = t.carrier
        for (i, pass) in chain.enumerated() {
            let gi = times[i]
            if u >= gi + passFlight {
                holder = pass.to
            } else if u >= gi {
                let f = (u - gi) / passFlight
                return Geo.lerp(animatedPos(pass.from, in: animIndex, u: u),
                                animatedPos(pass.to, in: animIndex, u: u), f)
            } else {
                break
            }
        }
        return animatedPos(holder, in: animIndex, u: u)
    }

    // MARK: Editing

    private func pushHistory() {
        history.append((touches, currentIndex))
        if history.count > 60 { history.removeFirst() }
    }

    func movePlayerStart(_ id: UUID, to pos: CGPoint) {
        let p = CGPoint(x: min(max(pos.x, 0), 1), y: min(max(pos.y, 0), 1))
        guard let team = player(id)?.team else { return }

        // A benched player (sub) comes on ONLY by being dropped onto the team-mate they are
        // replacing — an interchange. Dropped anywhere else, it snaps back to the bench.
        if isBenched(id, in: currentIndex) {
            if let target = nearestOnFieldTeammate(to: p, team: team, excluding: id) {
                pushHistory()
                interchange(sub: id, onField: target)
            }
            return
        }

        // An on-field player just repositions; dropping onto a bench is ignored (use an
        // interchange to take a player off), so a player never leaves the field by accident.
        if FieldLayout.benchTop.contains(p) || FieldLayout.benchBottom.contains(p) { return }
        pushHistory()
        touches[currentIndex].starts[id] = p
        if var run = touches[currentIndex].runs[id], !run.points.isEmpty {
            run.points[0] = p                                // keep the run attached to the token
            touches[currentIndex].runs[id] = run
        }
        propagateStarts(from: currentIndex)
    }

    /// Nearest on-field team-mate to a point (within a token's reach), for interchanges.
    private func nearestOnFieldTeammate(to p: CGPoint, team: Team, excluding: UUID) -> UUID? {
        let threshold: CGFloat = 0.09   // generous, so it is easy to land on with a finger
        var best: (id: UUID, dist: CGFloat)? = nil
        for pl in onField(in: currentIndex) where pl.team == team && pl.id != excluding {
            let d = Geo.dist(startPos(pl.id, in: currentIndex), p)
            if d <= threshold && (best == nil || d < best!.dist) { best = (pl.id, d) }
        }
        return best?.id
    }

    /// Swap a benched sub with an on-field team-mate for this touch: the sub takes the field
    /// spot (and the ball, if that player had it); the replaced player goes to the bench.
    private func interchange(sub subID: UUID, onField fieldID: UUID) {
        let benchSpot = startPos(subID, in: currentIndex)
        let fieldSpot = startPos(fieldID, in: currentIndex)
        touches[currentIndex].starts[subID] = fieldSpot
        touches[currentIndex].starts[fieldID] = benchSpot
        touches[currentIndex].runs[subID] = nil
        touches[currentIndex].runs[fieldID] = nil
        if touches[currentIndex].carrier == fieldID { touches[currentIndex].carrier = subID }
        propagateStarts(from: currentIndex)
    }

    /// Whether a player was off the field on the previous touch (or by default on touch 0),
    /// used to flag who has just come on / gone off this touch.
    func wasBenched(_ id: UUID, in index: Int) -> Bool {
        if index <= 0 { return player(id)?.isSub ?? false }
        return isBenched(id, in: index - 1)
    }
    func justCameOn(_ id: UUID, in index: Int) -> Bool {
        !isBenched(id, in: index) && wasBenched(id, in: index)
    }
    func justCameOff(_ id: UUID, in index: Int) -> Bool {
        isBenched(id, in: index) && !wasBenched(id, in: index)
    }

    func setRun(_ id: UUID, points: [CGPoint]) {
        guard points.count > 1 else { return }
        pushHistory()
        var pts = points
        pts[0] = startPos(id)   // anchor exactly to the token
        touches[currentIndex].runs[id] = RunLine(points: pts)
        reanchorPasses(for: id)
        propagateStarts(from: currentIndex)
    }

    /// Adds more points to the end of a player's existing run (e.g. the run-on after a pass).
    func appendRun(_ id: UUID, points: [CGPoint]) {
        guard var run = touches[currentIndex].runs[id], !run.points.isEmpty, !points.isEmpty else { return }
        pushHistory()
        run.points.append(contentsOf: points)
        touches[currentIndex].runs[id] = run
        reanchorPasses(for: id)
        propagateStarts(from: currentIndex)
    }

    /// Keeps a player's pass anchors at the same field point when their run changes length,
    /// by recomputing the progress fractions from the stored anchor points.
    private func reanchorPasses(for id: UUID) {
        guard let run = touches[currentIndex].runs[id], run.points.count > 1 else { return }
        for i in touches[currentIndex].passes.indices {
            if touches[currentIndex].passes[i].from == id {
                touches[currentIndex].passes[i].fromT =
                    Geo.nearestOnPolyline(touches[currentIndex].passes[i].fromPoint, run.points).t
            }
            if touches[currentIndex].passes[i].to == id {
                touches[currentIndex].passes[i].toT =
                    Geo.nearestOnPolyline(touches[currentIndex].passes[i].toPoint, run.points).t
            }
        }
    }

    func addPass(_ pass: Pass) {
        pushHistory()
        touches[currentIndex].passes.append(pass)
    }

    /// Re-anchor one end of an existing pass to a different player / point.
    func updatePass(id: UUID, end: PassEnd, player: UUID, point: CGPoint, t: CGFloat) {
        guard let idx = touches[currentIndex].passes.firstIndex(where: { $0.id == id }) else { return }
        pushHistory()
        switch end {
        case .from:
            touches[currentIndex].passes[idx].from = player
            touches[currentIndex].passes[idx].fromPoint = point
            touches[currentIndex].passes[idx].fromT = t
        case .to:
            touches[currentIndex].passes[idx].to = player
            touches[currentIndex].passes[idx].toPoint = point
            touches[currentIndex].passes[idx].toT = t
        }
    }

    /// After editing touch `index`, flow the new end positions forward so later touches
    /// start where the previous one finished (keeping their run/pass shapes).
    private func propagateStarts(from index: Int) {
        guard index >= 0, index + 1 < touches.count else { return }
        for i in (index + 1)..<touches.count {
            for p in roster {
                let newStart = endPos(p.id, in: i - 1)
                let old = touches[i].starts[p.id] ?? newStart
                let dx = newStart.x - old.x, dy = newStart.y - old.y
                touches[i].starts[p.id] = newStart
                if FieldLayout.benchTop.contains(newStart) || FieldLayout.benchBottom.contains(newStart) {
                    touches[i].runs[p.id] = nil          // stays subbed off — no run carried forward
                }
                guard dx != 0 || dy != 0 else { continue }
                if var run = touches[i].runs[p.id] {
                    run.points = run.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                    touches[i].runs[p.id] = run
                }
                for j in touches[i].passes.indices {
                    if touches[i].passes[j].from == p.id {
                        touches[i].passes[j].fromPoint.x += dx; touches[i].passes[j].fromPoint.y += dy
                    }
                    if touches[i].passes[j].to == p.id {
                        touches[i].passes[j].toPoint.x += dx; touches[i].passes[j].toPoint.y += dy
                    }
                }
            }
            if touches[i].start == .playTheBall {
                touches[i].startMark = endPos(finalCarrier(in: i - 1), in: i - 1)
            }
            // Re-derive pass progress fractions for the shifted runs.
            for j in touches[i].passes.indices {
                let pass = touches[i].passes[j]
                if let run = touches[i].runs[pass.from], run.points.count > 1 {
                    touches[i].passes[j].fromT = Geo.nearestOnPolyline(pass.fromPoint, run.points).t
                }
                if let run = touches[i].runs[pass.to], run.points.count > 1 {
                    touches[i].passes[j].toT = Geo.nearestOnPolyline(touches[i].passes[j].toPoint, run.points).t
                }
            }
        }
    }

    /// Coaching automation: on each touch after the first, give every on-field defender with
    /// no run yet a "press up 3 m, then slide back onside" run. The first touch (the initial
    /// set) never retreats. The retreat targets the onside line — 10 m behind where the
    /// ball-carrier is touched — rather than a fixed distance behind each defender, so the
    /// line does not drift a further 7 m back every play when the attack makes no ground.
    private func fillDefenceRetreat(_ index: Int) {
        guard index >= 1 else { return }   // touch 0 is the set line — it holds, no retreat
        let d3 = FieldLayout.metresToFx(3) * FieldLayout.field.width
        let onside = FieldLayout.metresToFx(7) * FieldLayout.field.width
        let minX = FieldLayout.field.minX + 0.005
        let maxX = FieldLayout.field.maxX - 0.005
        // Defenders finish 7 m behind the ruck (the play-the-ball mark) for this touch.
        // Keying off the mark — not the ball-carrier — keeps the line a fixed 7 m off the
        // play without creeping forward or drifting back when the attack makes no ground.
        let ruckX = touches[index].startMark?.x ?? endPos(finalCarrier(in: index), in: index).x
        let onsideX = min(max(ruckX + onside, minX), maxX)
        for p in onField(in: index) where p.team == .defence {
            guard touches[index].runs[p.id] == nil else { continue }
            let s = startPos(p.id, in: index)
            let up = CGPoint(x: min(max(s.x - d3, minX), maxX), y: s.y)   // press up toward the attack
            let back = CGPoint(x: onsideX, y: s.y)                        // slide back to the onside line
            touches[index].runs[p.id] = RunLine(points: [s, up, back])
        }
    }

    func setCarrier(_ id: UUID) {
        guard player(id) != nil, !isBenched(id, in: currentIndex) else { return }
        pushHistory()
        touches[currentIndex].carrier = id
    }

    /// Who holds the ball at the END of a touch, following any passes made during it.
    func finalCarrier(in index: Int) -> UUID {
        let t = touches[index]
        var holder = t.carrier
        for pass in t.passes.sorted(by: { $0.fromT < $1.fromT }) { holder = pass.to }
        return holder
    }

    func playTheBall() {
        pushHistory()
        // Auto defence: everyone bar the touch-maker presses up then retreats to the mark.
        fillDefenceRetreat(currentIndex)
        // Whoever has the ball at the end of the touch (after passes) plays the ball.
        let touched = finalCarrier(in: currentIndex)
        let ruck = endPos(touched, in: currentIndex)
        touches[currentIndex].rollballAt = ruck

        // Advance to a new touch only from the last one, capped at maxTouches.
        guard currentIndex == touches.count - 1, touches.count < Self.maxTouches else {
            if currentIndex < touches.count - 1 { currentIndex += 1 }
            return
        }
        var starts: [UUID: CGPoint] = [:]
        for p in roster { starts[p.id] = endPos(p.id, in: currentIndex) }
        // Defence retreats at the play-the-ball: reset to a flat line 7 m behind the new ruck.
        let d7 = FieldLayout.metresToFx(7) * FieldLayout.field.width
        let onsideX = min(max(ruck.x + d7, FieldLayout.field.minX + 0.005),
                          FieldLayout.field.maxX - 0.005)
        for p in roster where p.team == .defence && !isBenched(p.id, in: currentIndex) {
            if let cur = starts[p.id] { starts[p.id] = CGPoint(x: onsideX, y: cur.y) }
        }
        // The dummy half (nearest attacker behind the ruck) picks up to start the next touch.
        let dummy = dummyHalf(near: ruck, excluding: touched, endsIndex: currentIndex) ?? touched
        touches.append(Touch(starts: starts, carrier: dummy, start: .playTheBall, startMark: ruck))
        currentIndex = touches.count - 1
    }

    /// The attacker (other than the player who played the ball) whose end position is
    /// closest to the ruck — i.e. the acting/dummy half who picks up.
    private func dummyHalf(near ruck: CGPoint, excluding: UUID, endsIndex: Int) -> UUID? {
        var best: (id: UUID, dist: CGFloat)? = nil
        for p in onField(in: endsIndex) where p.team == .attack && p.id != excluding {
            let d = Geo.dist(endPos(p.id, in: endsIndex), ruck)
            if best == nil || d < best!.dist { best = (p.id, d) }
        }
        return best?.id
    }

    /// Choose how the set starts (tap or play-the-ball); rebuilds from the current position.
    func setStartType(_ s: TouchStart) {
        stopAnimation()
        pushHistory()
        applyStart(s, startPosition, resetHistory: false)
    }

    /// Choose where on the field the set starts; rebuilds keeping the current start type.
    func setStartPosition(_ p: StartPosition) {
        stopAnimation()
        pushHistory()
        applyStart(touches.first?.start ?? .tap, p, resetHistory: false)
    }

    func selectTouch(_ index: Int) {
        stopAnimation()
        currentIndex = min(max(index, 0), touches.count - 1)
    }

    var canAddTouch: Bool { currentIndex == touches.count - 1 && touches.count < Self.maxTouches }

    // MARK: Erase / undo / clear

    /// Removes the nearest run / pass / rollball to a normalised point.
    func eraseNearest(to point: CGPoint, threshold: CGFloat = 0.05) {
        var best: (dist: CGFloat, action: () -> Void)? = nil
        func consider(_ d: CGFloat, _ action: @escaping () -> Void) {
            if d <= threshold && (best == nil || d < best!.dist) { best = (d, action) }
        }

        let t = touches[currentIndex]
        for (id, run) in t.runs {
            let n = Geo.nearestOnPolyline(point, run.points)
            consider(n.dist) { [weak self] in self?.touches[self!.currentIndex].runs[id] = nil }
        }
        for pass in t.passes {
            let d = min(Geo.dist(point, pass.fromPoint), Geo.dist(point, pass.toPoint))
            consider(d) { [weak self] in
                self?.touches[self!.currentIndex].passes.removeAll { $0.id == pass.id }
            }
        }
        if let rb = t.rollballAt {
            consider(Geo.dist(point, rb)) { [weak self] in
                self?.touches[self!.currentIndex].rollballAt = nil
            }
        }

        if let best {
            pushHistory()
            best.action()
            propagateStarts(from: currentIndex)
        }
    }

    func undo() {
        stopAnimation()
        guard let last = history.popLast() else { return }
        touches = last.touches
        currentIndex = min(last.index, touches.count - 1)
    }

    func clearTouch() {
        pushHistory()
        touches[currentIndex].runs.removeAll()
        touches[currentIndex].passes.removeAll()
        touches[currentIndex].rollballAt = nil
        propagateStarts(from: currentIndex)
    }

    // MARK: Animation control

    func playTouch() {
        pushHistory()
        fillDefenceRetreat(currentIndex)
        propagateStarts(from: currentIndex)
        start(scope: [currentIndex])
    }
    func playSet() {
        pushHistory()
        for i in touches.indices {
            fillDefenceRetreat(i)
            propagateStarts(from: i)
        }
        start(scope: Array(0..<touches.count))
    }

    private func start(scope: [Int]) {
        stopAnimation()
        guard !scope.isEmpty else { return }
        self.scope = scope
        scopePos = 0
        transitioning = false
        transElapsed = 0
        animIndex = scope[0]
        animU = 0
        elapsed = 0
        lastTick = Date()
        isAnimating = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        isAnimating = false
        transitioning = false
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick ?? now)
        lastTick = now

        // Between-touch transition: hold players at the ruck while the ball is picked up.
        if transitioning {
            transElapsed += dt
            if transElapsed >= transitionDuration {
                scopePos += 1
                transitioning = false
                if scopePos < scope.count {
                    animIndex = scope[scopePos]; animU = 0; elapsed = 0
                } else {
                    animU = 1; stopAnimation()
                }
            }
            return
        }

        elapsed += dt
        if elapsed >= touchDuration {
            animU = 1
            if scopePos + 1 < scope.count {
                transitioning = true          // roll into the next touch smoothly
                transElapsed = 0
            } else {
                stopAnimation()
            }
            return
        }
        animU = min(CGFloat(elapsed / touchDuration), 1)
    }
}
