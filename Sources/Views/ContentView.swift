import SwiftUI

struct ContentView: View {
    @StateObject private var store = PlayStore()
    @State private var exportItem: ExportItem?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(store: store)
            TouchBarView(store: store, isExporting: isExporting, onExport: runExport)

            GeometryReader { geo in
                let size = geo.size
                let canvasActive = (store.tool == .run || store.tool == .pass || store.tool == .erase) && !store.isAnimating

                ZStack {
                    FieldView()

                    PlayCanvasView(store: store, areaSize: size)
                        .allowsHitTesting(canvasActive)

                    // All players in one layer; on/off is per touch (a bench player can be
                    // dragged on in Move mode, an on-field player dragged off).
                    ForEach(store.roster) { player in
                        // Tokens handle drags in Move/Ball; in Run/Pass/Erase the canvas owns
                        // all drags (including sub interchanges), so the two never conflict.
                        let active = !store.isAnimating
                            && (store.tool == .position || store.tool == .ball)
                        PlayerTokenView(store: store, player: player, areaSize: size)
                            .allowsHitTesting(active)
                    }
                }
                .coordinateSpace(name: "play")
            }
            .background(Color(white: 0.08))
        }
        .background(Color(white: 0.08))
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay { if isExporting { exportingOverlay } }
        .sheet(item: $exportItem) { ShareSheet(url: $0.url) }
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text("Exporting animation…").foregroundStyle(.white).font(.headline)
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.15)))
        }
    }

    private func runExport() {
        guard !isExporting else { return }
        store.stopAnimation()
        isExporting = true
        Task {
            let url = await AnimationExporter.export(store: store)
            isExporting = false
            if let url { exportItem = ExportItem(url: url) }
        }
    }
}

#Preview {
    ContentView()
}
