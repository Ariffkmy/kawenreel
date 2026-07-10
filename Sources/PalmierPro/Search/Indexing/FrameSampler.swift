import AVFoundation
import CoreGraphics
import Foundation

/// Streams visually distinct frames for indexing. A dense low-res scan scores every
/// frame for scene changes (exact cut times), then only the picked frames are decoded
/// at full sampling resolution. A coverage floor keeps long static shots represented;
/// near-duplicate coverage frames are dropped against a window of recent keeps.
enum FrameSampler {
    static let samplerVersion = 2

    struct Options {
        var promoteDiff: Float = 12
        var minShotGap: Double = 0.35
        var coverageFloor: Double = 8.0
        var dedupDiff: Float = 5
        var dedupWindow: Int = 4
        /// Cut frames are often transition blur; embed a beat into the shot instead.
        var stabilizeOffset: Double = 0.15
        var maxSize = CGSize(width: 512, height: 512)
        var scanEdge: CGFloat = 160
    }

    struct Frame {
        let time: Double
        let image: CGImage
        let isNewShot: Bool
    }

    static func frames(url: URL, duration: Double, options: Options = Options()) -> AsyncThrowingStream<Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await sample(url: url, duration: duration, options: options) { frame in
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Pick {
        let time: Double
        let imageTime: Double
        let isNewShot: Bool
    }

    private static func sample(
        url: URL,
        duration: Double,
        options: Options,
        emit: (Frame) -> Void
    ) async throws {
        guard duration > 0 else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }

        var picks = (try? await scanPicks(asset: asset, track: track, options: options)) ?? []
        if picks.isEmpty {
            try await sampleSparse(asset: asset, track: track, duration: duration, options: options, emit: emit)
            return
        }
        // Clamp so the stabilized time never lands past the final frame.
        picks = picks.map {
            Pick(time: $0.time, imageTime: min($0.imageTime, max($0.time, duration - 0.05)), isNewShot: $0.isNewShot)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = options.maxSize
        // Tighter than stabilizeOffset so a grab can't cross the cut it stabilizes from.
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = picks.map { CMTime(seconds: $0.imageTime, preferredTimescale: 600) }
        var index = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            defer { index += 1 }
            guard index < picks.count, case .success(_, let image, _) = result else { continue }
            emit(Frame(time: picks[index].time, image: image, isNewShot: picks[index].isNewShot))
        }
    }

    /// Dense pass: decode every frame small, fingerprint it, and decide cuts,
    /// coverage-floor keeps, and dedup drops — without keeping any pixels around.
    private static func scanPicks(
        asset: AVURLAsset, track: AVAssetTrack, options: Options
    ) async throws -> [Pick] {
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }

        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let longEdge = max(abs(natural.width), abs(natural.height))
        if longEdge > options.scanEdge {
            let scale = options.scanEdge / longEdge
            settings[kCVPixelBufferWidthKey as String] = max(16, Int(abs(natural.width) * scale)) & ~1
            settings[kCVPixelBufferHeightKey as String] = max(16, Int(abs(natural.height) * scale)) & ~1
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CancellationError() }

        var picks: [Pick] = []
        var recentKept: [[Float]] = []
        var previous: [Float]?
        var lastCut = -Double.infinity
        var lastKept = -Double.infinity
        var frameCount = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            frameCount += 1
            if frameCount % 64 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard t.isFinite, let grid = ColorGrid.compute(buffer) else { continue }

            let isCut: Bool
            if let previous {
                isCut = ColorGrid.meanDiff(grid, previous) > options.promoteDiff
                    && t - lastCut >= options.minShotGap
            } else {
                isCut = true
            }
            previous = grid

            if isCut {
                picks.append(Pick(time: t, imageTime: t + options.stabilizeOffset, isNewShot: true))
                lastCut = t
                lastKept = t
                keep(grid, in: &recentKept, window: options.dedupWindow)
            } else if t - lastKept >= options.coverageFloor {
                lastKept = t
                if recentKept.allSatisfy({ ColorGrid.meanDiff(grid, $0) > options.dedupDiff }) {
                    picks.append(Pick(time: t, imageTime: t, isNewShot: false))
                    keep(grid, in: &recentKept, window: options.dedupWindow)
                }
            }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? CancellationError() }
        return picks
    }

    private static func keep(_ grid: [Float], in recent: inout [[Float]], window: Int) {
        recent.append(grid)
        if recent.count > window { recent.removeFirst() }
    }

    /// Fallback when the dense scan can't read the asset: sparse candidates via the
    /// image generator, scene changes detected between candidates only.
    private static func sampleSparse(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: Double,
        options: Options,
        emit: (Frame) -> Void
    ) async throws {
        var interval = 2.0
        if let size = try? await track.load(.naturalSize),
           max(abs(size.width), abs(size.height)) >= 3000 {
            interval *= 2
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = options.maxSize
        // ≥1s lets the decoder grab the nearest sync frame
        let tolerance = CMTime(seconds: max(interval / 2, 1.0), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var seconds = Array(stride(from: interval / 2, to: duration, by: interval))
        if seconds.isEmpty { seconds = [duration / 2] }
        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }

        var lastGrid: [Float]?
        var lastKeptTime = -Double.infinity
        var lastTime = -Double.infinity
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard case .success(_, let image, let actualTime) = result else { continue }
            let t = actualTime.seconds
            guard t > lastTime else { continue }
            lastTime = t
            guard let grid = LumaGrid.compute(image) else { continue }

            let isNewShot: Bool
            if let last = lastGrid {
                isNewShot = LumaGrid.meanDiff(grid, last) > options.promoteDiff
            } else {
                isNewShot = true
            }
            lastGrid = grid

            guard isNewShot || t - lastKeptTime >= options.coverageFloor else { continue }
            lastKeptTime = t
            emit(Frame(time: t, image: image, isNewShot: isNewShot))
        }
    }
}

/// Mean RGB per cell of an 8×8 downsample — like LumaGrid, but chroma-aware so
/// equal-brightness color cuts still register.
enum ColorGrid {
    static let cells = 8
    private static let samplesPerCell = 3

    static func compute(_ buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let n = cells
        let s = samplesPerCell
        var out = [Float](repeating: 0, count: n * n * 3)
        for cy in 0..<n {
            for cx in 0..<n {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for sy in 0..<s {
                    for sx in 0..<s {
                        let x = ((cx * s + sx) * 2 + 1) * width / (n * s * 2)
                        let y = ((cy * s + sy) * 2 + 1) * height / (n * s * 2)
                        let p = y * bytesPerRow + x * 4
                        b += Float(pixels[p])
                        g += Float(pixels[p + 1])
                        r += Float(pixels[p + 2])
                    }
                }
                let count = Float(s * s)
                let i = (cy * n + cx) * 3
                out[i] = r / count
                out[i + 1] = g / count
                out[i + 2] = b / count
            }
        }
        return out
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var diff: Float = 0
        for i in a.indices { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count)
    }
}

/// Mean luma per cell of an 8×8 downsample — cheap visual-change fingerprint.
enum LumaGrid {
    static let cells = 8

    static func compute(_ image: CGImage) -> [Float]? {
        let n = cells
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(
            data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return (0..<n * n).map { i in
            Float(pixels[i * 4]) * 0.299 + Float(pixels[i * 4 + 1]) * 0.587 + Float(pixels[i * 4 + 2]) * 0.114
        }
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        var diff: Float = 0
        for i in 0..<a.count { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count)
    }
}
