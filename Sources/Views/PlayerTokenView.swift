import SwiftUI

/// A single player disc. Position comes from the store (start position while editing,
/// animated position while playing). Draggable in Move mode; tappable in Ball mode.
struct PlayerTokenView: View {
    @ObservedObject var store: PlayStore
    let player: Player
    let areaSize: CGSize

    private let diameter: CGFloat = 40

    @State private var dragOffset: CGSize = .zero

    var body: some View {
        let pos = store.displayPos(player.id)
        let center = CGPoint(x: pos.x * areaSize.width, y: pos.y * areaSize.height)
        let idx = store.displayIndex
        let benched = store.isBenched(player.id, in: idx)
        let cameOn = store.justCameOn(player.id, in: idx)
        let cameOff = store.justCameOff(player.id, in: idx)
        let hasBall = !store.isAnimating && !store.isRendering && store.currentTouch.carrier == player.id
        let isBallTarget = store.tool == .ball && !benched

        let armed = store.armedSub == player.id
        let ringColor: Color = armed ? .cyan : (cameOn ? .green : (hasBall ? .yellow : .white))
        let ringWidth: CGFloat = (armed || cameOn) ? 3.5 : (hasBall ? 3 : 2)

        ZStack {
            Circle()
                .fill(cameOff ? Color(white: 0.5) : player.team.color)   // grey a player subbed off
                .overlay(Circle().stroke(ringColor, lineWidth: ringWidth))
                .shadow(color: armed ? .cyan.opacity(0.9) : (cameOn ? .green.opacity(0.85) : .black.opacity(0.4)),
                        radius: (armed || cameOn) ? 6 : 2, y: (armed || cameOn) ? 0 : 1)
            Text(player.label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            if hasBall {
                Ellipse()
                    .fill(Color(red: 0.64, green: 0.40, blue: 0.19))
                    .overlay(Ellipse().stroke(.white, lineWidth: 1.5))
                    .frame(width: 22, height: 14)
                    .shadow(color: .yellow.opacity(0.6), radius: 3)
                    .offset(x: diameter * 0.46, y: -diameter * 0.34)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(cameOff ? 0.55 : 1)
        .scaleEffect((armed || cameOn) ? 1.12 : (isBallTarget ? 1.08 : 1.0))
        .position(x: center.x + dragOffset.width, y: center.y + dragOffset.height)
        .highPriorityGesture(interaction(center: center, benched: benched))
    }

    private func interaction(center: CGPoint, benched: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if store.tool == .position && !benched { dragOffset = value.translation }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                if moved < 10 {
                    // A tap: set the ball carrier in Ball mode; otherwise tap a bench sub to
                    // bring it on. (tapPlayer only acts on benched players.)
                    if store.tool == .ball && !benched {
                        store.setCarrier(player.id)
                    } else {
                        store.tapPlayer(player.id)
                    }
                    dragOffset = .zero
                    return
                }
                // A drag only repositions an on-field player in Move mode.
                if !benched && store.tool == .position {
                    let nx = (center.x + value.translation.width) / areaSize.width
                    let ny = (center.y + value.translation.height) / areaSize.height
                    store.movePlayerStart(player.id, to: CGPoint(x: nx, y: ny))
                }
                dragOffset = .zero
            }
    }
}
