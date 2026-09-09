import SwiftUI

struct ToolbarView: View {
    @ObservedObject var store: PlayStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Tool.allCases) { tool in
                Button {
                    store.stopAnimation()
                    store.tool = tool
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                        Text(tool.title).font(.caption2)
                    }
                    .frame(width: 62, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(store.tool == tool ? Color.accentColor : Color(white: 0.22))
                    )
                    .foregroundStyle(store.tool == tool ? Color.white : Color(white: 0.85))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            Text("B15")
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Capsule().fill(Color.orange))
                .foregroundStyle(.black)

            if let armed = store.armedSub, let label = store.player(armed)?.label {
                Text("Tap a player to bring \(label) on")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            } else {
                hint
            }

            Spacer(minLength: 8)

            action("Undo", "arrow.uturn.backward") { store.undo() }
            action("Clear", "trash") { store.clearTouch() }
            action("Reset", "arrow.counterclockwise") { store.resetAll() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    @ViewBuilder private var hint: some View {
        let text: String = {
            switch store.tool {
            case .position: return "Drag players to set where they start this touch"
            case .run: return "Drag from a player to draw their run"
            case .pass: return "Drag between run lines to pass · drag a pass's dot to re-target"
            case .ball: return "Tap a player to give them the ball"
            case .erase: return "Tap a run, pass or rollball to remove it"
            }
        }()
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color(white: 0.6))
            .lineLimit(1)
    }

    private func action(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption2)
            }
            .frame(width: 58, height: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.22)))
            .foregroundStyle(Color(white: 0.85))
        }
        .buttonStyle(.plain)
    }
}
