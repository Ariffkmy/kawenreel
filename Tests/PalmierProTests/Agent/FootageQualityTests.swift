import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("analyze_footage_quality — synthetic stability")
@MainActor
struct FootageQualityTests {

    @Test func separatesStableFromShakyFootage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-footage-quality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stableURL = dir.appendingPathComponent("stable.mov")
        let shakyURL = dir.appendingPathComponent("shaky.mov")
        try await SyntheticFootage.write(to: stableURL, jitterAmplitude: 0)
        try await SyntheticFootage.write(to: shakyURL, jitterAmplitude: 8)

        let stable = try await analyze(url: stableURL)
        let shaky = try await analyze(url: shakyURL)

        let stableWindows = try #require(stable["windows"] as? [[String: Any]])
        let shakyWindows = try #require(shaky["windows"] as? [[String: Any]])
        #expect(!stableWindows.isEmpty && !shakyWindows.isEmpty)

        #expect(stableWindows.allSatisfy { ($0["stability"] as? String) != "shaky" })
        #expect(shakyWindows.allSatisfy { ($0["stability"] as? String) == "shaky" })
        #expect(shakyWindows.allSatisfy { ($0["isUsable"] as? Bool) == false })
        #expect((shaky["bestRanges"] as? [[String: Any]])?.isEmpty == true)

        #expect((stable["bestRanges"] as? [[String: Any]])?.isEmpty == false)

        let stableJitter = stableWindows.compactMap { $0["jitter"] as? Double }.max() ?? 0
        let shakyJitter = shakyWindows.compactMap { $0["jitter"] as? Double }.min() ?? 0
        #expect(shakyJitter > stableJitter * 3)
    }

    private func analyze(url: URL) async throws -> [String: Any] {
        let h = ToolHarness()
        let asset = MediaAsset(id: UUID().uuidString, url: url, type: .video, name: url.lastPathComponent, duration: 3)
        h.editor.mediaAssets.append(asset)
        let json = try await h.runOK("analyze_footage_quality", args: ["mediaRef": asset.id])
        return try #require(json as? [String: Any])
    }
}

/// Renders a textured pan; jitterAmplitude adds per-frame random offset on top (handheld shake).
private enum SyntheticFootage {
    static let width = 640
    static let height = 360
    static let fps = 30
    static let frames = 90

    static func write(to url: URL, jitterAmplitude: Int) async throws {
        let margin = 96
        let texture = makeTexture(width: width + margin * 2, height: height + margin * 2)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var rng = SplitMix64(seed: 0x5EED)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let pan = Double(i) * 0.5
            var ox = margin / 2 + Int(pan.rounded())
            var oy = margin / 2
            if jitterAmplitude > 0 {
                ox += Int(rng.next(in: -jitterAmplitude...jitterAmplitude))
                oy += Int(rng.next(in: -jitterAmplitude...jitterAmplitude))
            }
            guard let pool = adaptor.pixelBufferPool else { throw ToolError("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ToolError("pixel buffer allocation failed") }
            fill(buffer, texture: texture, textureWidth: width + margin * 2, ox: ox, oy: oy)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ToolError("writer failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Blocky seeded noise — strong edges for registration, cheap to H.264-encode.
    private static func makeTexture(width: Int, height: Int) -> [UInt8] {
        var rng = SplitMix64(seed: 42)
        let block = 16
        let bw = (width + block - 1) / block
        let bh = (height + block - 1) / block
        let blocks = (0..<bw * bh).map { _ in UInt8(rng.next(in: 30...220)) }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = blocks[(y / block) * bw + (x / block)]
            }
        }
        return out
    }

    private static func fill(_ buffer: CVPixelBuffer, texture: [UInt8], textureWidth: Int, ox: Int, oy: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = dst + y * stride
            let srcRow = (y + oy) * textureWidth
            for x in 0..<width {
                let v = texture[srcRow + x + ox]
                row[x * 4] = v
                row[x * 4 + 1] = v
                row[x * 4 + 2] = v
                row[x * 4 + 3] = 255
            }
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}
