import SwiftUI

/// Touch (phase) selector chips plus the play-the-ball and animation controls.
struct TouchBarView: View {
    @ObservedObject var store: PlayStore
    var isExporting: Bool = false
    var onExport: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text("SET")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(white: 0.6))

            ForEach(Array(store.touches.enumerated()), id: \.element.id) { index, _ in
                Button {
                    store.selectTouch(index)
                } label: {
                    Text("\(index)")
                        .font(.headline.weight(.bold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(index == store.currentIndex
                                          ? Color.accentColor : Color(white: 0.24))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(store.isAnimating)
            }

            if store.touches.count >= PlayStore.maxTouches {
                Text("• handover")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if store.currentIndex == 0 && !store.isAnimating {
                startToggle
                positionToggle
            }

            Spacer(minLength: 12)

            action("Play the ball", "figure.australian.football",
                   enabled: !store.isAnimating) { store.playTheBall() }

            Divider().frame(height: 40).overlay(Color.white.opacity(0.2))

            if store.isAnimating {
                action("Stop", "stop.fill", tint: .red) { store.stopAnimation() }
            } else {
                action("Play touch", "play.fill", tint: .green) { store.playTouch() }
                action("Play set", "play.rectangle.fill", tint: .green) { store.playSet() }
            }

            Divider().frame(height: 40).overlay(Color.white.opacity(0.2))
            action("Export", "square.and.arrow.up", tint: .cyan, enabled: !isExporting, action: onExport)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.14))
    }

    private var startToggle: some View {
        HStack(spacing: 4) {
            Text("Start:").font(.caption).foregroundStyle(Color(white: 0.55))
            seg("Tap", active: store.currentTouch.start == .tap) { store.setStartType(.tap) }
            seg("Play the ball", active: store.currentTouch.start == .playTheBall) {
                store.setStartType(.playTheBall)
            }
        }
        .padding(.leading, 6)
    }

    private var positionToggle: some View {
        HStack(spacing: 4) {
            Text("From:").font(.caption).foregroundStyle(Color(white: 0.55))
            ForEach(StartPosition.allCases) { pos in
                seg(pos.label, active: store.startPosition == pos) { store.setStartPosition(pos) }
            }
        }
        .padding(.leading, 6)
    }

    private func seg(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.accentColor : Color(white: 0.24)))
                .foregroundStyle(active ? .white : Color(white: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, _ icon: String, tint: Color = Color(white: 0.85),
                        enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.24)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
