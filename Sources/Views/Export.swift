import SwiftUI
import AVFoundation
import UIKit

/// A single rendered frame of the play (field + annotations + players + ball) at a fixed size.
/// Positions come from the store's frame override, so it reuses all the live drawing.
struct ExportStack: View {
    @ObservedObject var store: PlayStore
    let size: CGSize

    var body: some View {
        ZStack {
            Color(white: 0.08)
            FieldView()
            PlayCanvasView(store: store).allowsHitTesting(false)
            ForEach(store.roster) { p in
                PlayerTokenView(store: store, player: p, areaSize: size)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }
}

/// Wraps a file in the system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Renders every frame of the whole set and encodes an MP4.
enum AnimationExporter {
    @MainActor
    static func export(store: PlayStore) async -> URL? {
        let size = CGSize(width: 1400, height: 920)
        let fps = 20
        func smooth(_ t: CGFloat) -> CGFloat { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }

        // Build the frame descriptors for the whole set.
        var frames: [(index: Int, u: CGFloat, ball: CGPoint, flightFrom: CGPoint?)] = []
        let count = store.touches.count
        let tSteps = max(1, Int(store.animTouchDuration * Double(fps)))
        let trSteps = max(1, Int(store.animTransitionDuration * Double(fps)))
        for idx in 0..<count {
            for s in 0...tSteps {
                let u = CGFloat(s) / CGFloat(tSteps)
                frames.append((idx, u, store.frameBall(index: idx, u: u),
                               store.frameFlightFrom(index: idx, u: u)))
            }
            if idx < count - 1 {
                let from = store.endPos(store.finalCarrier(in: idx), in: idx)
                let to = store.startPos(store.touches[idx + 1].carrier, in: idx + 1)
                for s in 1...trSteps {
                    let tu = CGFloat(s) / CGFloat(trSteps)
                    frames.append((idx, 1, Geo.lerp(from, to, smooth(tu)), from))
                }
            }
        }
        guard !frames.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchBoard-play.mp4")
        try? FileManager.default.removeItem(at: url)
        guard let writer = VideoWriter(size: size, fps: fps, url: url) else { return nil }
        writer.start()

        for (i, f) in frames.enumerated() {
            store.setRenderFrame(index: f.index, u: f.u, ball: f.ball, flightFrom: f.flightFrom)
            let renderer = ImageRenderer(content: ExportStack(store: store, size: size))
            renderer.scale = 1
            if let cg = renderer.cgImage { writer.append(cg, frame: i) }
            if i % 8 == 0 { await Task.yield() }   // let the UI breathe
        }
        store.clearRenderFrame()
        await writer.finish()
        return url
    }
}

/// Minimal H.264 MP4 writer fed one CGImage per frame.
final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int

    init?(size: CGSize, fps: Int, url: URL) {
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        writer = w
        self.fps = fps
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, frame: Int) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.003) }
        guard let pool = adaptor.pixelBufferPool,
              let buffer = Self.pixelBuffer(from: image, pool: pool) else { return }
        adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps)))
    }

    func finish() async {
        await withCheckedContinuation { cont in
            input.markAsFinished()
            writer.finishWriting { cont.resume() }
        }
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
