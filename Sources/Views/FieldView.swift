import SwiftUI

/// Draws the touch football field markings plus the two sub boxes (one on each
/// sideline, centred on halfway). Length runs horizontally; width is vertical.
struct FieldView: View {
    private let grass = Color(red: 0.29, green: 0.55, blue: 0.30)
    private let grassAlt = Color(red: 0.32, green: 0.58, blue: 0.33)
    private let line = Color.white.opacity(0.9)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let f = denorm(FieldLayout.field, in: size)

            ZStack {
                Canvas { ctx, _ in drawField(ctx: &ctx, rect: f) }
                benchBox(denorm(FieldLayout.benchTop, in: size),
                         title: "DEFENCE SUBS", tint: Team.defence.color)
                benchBox(denorm(FieldLayout.benchBottom, in: size),
                         title: "ATTACK SUBS", tint: Team.attack.color)
            }
        }
    }

    // MARK: Field

    private func drawField(ctx: inout GraphicsContext, rect f: CGRect) {
        // Grass with mowing stripes along the length.
        let stripes = 10
        for i in 0..<stripes {
            let w = f.width / CGFloat(stripes)
            let r = CGRect(x: f.minX + CGFloat(i) * w, y: f.minY, width: w, height: f.height)
            ctx.fill(Path(r), with: .color(i % 2 == 0 ? grass : grassAlt))
        }

        let stroke = StrokeStyle(lineWidth: 2)
        let dashed = StrokeStyle(lineWidth: 2, dash: [8, 7])

        func vLine(atFx x: CGFloat, style: StrokeStyle) {
            var p = Path()
            let px = f.minX + f.width * x
            p.move(to: CGPoint(x: px, y: f.minY))
            p.addLine(to: CGPoint(x: px, y: f.maxY))
            ctx.stroke(p, with: .color(line), style: style)
        }

        // Outer boundary (sidelines + dead-ball ends).
        ctx.stroke(Path(f), with: .color(line), style: stroke)

        // In-goal (touchdown) shading beyond each try line.
        for zone in [CGRect(x: f.minX, y: f.minY,
                            width: f.width * FieldLayout.tryLeft, height: f.height),
                     CGRect(x: f.minX + f.width * FieldLayout.tryRight, y: f.minY,
                            width: f.width * (1 - FieldLayout.tryRight), height: f.height)] {
            ctx.fill(Path(zone), with: .color(.white.opacity(0.06)))
        }

        // Try / score lines, halfway, and the 5 m retreat lines (dashed).
        vLine(atFx: FieldLayout.tryLeft, style: stroke)
        vLine(atFx: FieldLayout.tryRight, style: stroke)
        vLine(atFx: FieldLayout.halfway, style: stroke)
        vLine(atFx: FieldLayout.tryLeft + FieldLayout.metresToFx(5), style: dashed)
        vLine(atFx: FieldLayout.tryRight - FieldLayout.metresToFx(5), style: dashed)

        // Halfway dot.
        let dot = CGRect(x: f.midX - 3, y: f.midY - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dot), with: .color(line))
    }

    // MARK: Sub boxes

    private func benchBox(_ b: CGRect, title: String, tint: Color) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.55), lineWidth: 1))
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint.opacity(0.9))
                .padding(.top, 2)
        }
        .frame(width: b.width, height: b.height)
        .position(x: b.midX, y: b.midY)
    }

    private func denorm(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height,
               width: r.width * size.width, height: r.height * size.height)
    }
}
