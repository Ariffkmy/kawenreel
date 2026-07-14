import AVFoundation
import CoreGraphics
import Foundation
import Vision

extension ToolExecutor {
    private static let analyzeFootageQualityAllowedKeys: Set<String> = [
        "mediaRef", "clipId", "startSeconds", "endSeconds", "sampleFPS", "windowSeconds"
    ]

    func analyzeFootageQuality(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.analyzeFootageQualityAllowedKeys, path: "analyze_footage_quality")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video else {
            throw ToolError("analyze_footage_quality: \(asset.name) is not a video asset.")
        }
        guard asset.duration > 0 else {
            throw ToolError("analyze_footage_quality: \(asset.name) has zero duration.")
        }

        let start = max(0, args.double("startSeconds") ?? 0)
        let end = min(asset.duration, args.double("endSeconds") ?? asset.duration)
        guard end > start else {
            throw ToolError("analyze_footage_quality: endSeconds must be greater than startSeconds.")
        }
        let windowSeconds = min(max(args.double("windowSeconds") ?? 2, 0.75), 6)

        let mapping = try clipMapping(editor: editor, mediaRef: asset.id, clipId: args.string("clipId"))
        let analysis = try await FootageQualityAnalyzer.analyze(
            url: asset.url,
            start: start,
            end: end,
            windowSeconds: windowSeconds,
            fps: editor.timeline.fps,
            clip: mapping
        )

        var payload = analysis
        payload["mediaRef"] = asset.id
        payload["name"] = asset.name
        payload["durationSeconds"] = asset.duration
        payload["windowSeconds"] = windowSeconds
        if let mapping {
            payload["timelineMapping"] = Self.timelineMappingMeta(clip: mapping, fps: editor.timeline.fps)
        }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("analyze_footage_quality: failed to encode result.")
        }
        return .ok(json)
    }

    private func clipMapping(editor: EditorViewModel, mediaRef: String, clipId: String?) throws -> Clip? {
        guard let clipId else { return nil }
        // Models pass the mediaRef again as clipId; treat that as a library-only call.
        if clipId == mediaRef, editor.findClip(id: clipId) == nil { return nil }
        guard let loc = editor.findClip(id: clipId) else {
            throw ToolError("analyze_footage_quality: clipId not found: \(clipId). clipId is a TIMELINE clip id from get_timeline — omit it to analyze the library asset directly.")
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaRef == mediaRef else {
            throw ToolError("analyze_footage_quality: clip \(clipId) does not reference mediaRef \(mediaRef).")
        }
        return clip
    }
}

/// Exposure classification over luma planes (0–255). Internal so it's unit-testable.
enum FootageExposure {
    static func classify(planes: [[Float]]) -> (label: String, mean: Double, shadow: Double, highlight: Double) {
        let nonEmpty = planes.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return ("ok", 0, 0, 0) }
        var sum = 0.0, shadow = 0.0, highlight = 0.0, count = 0.0
        for plane in nonEmpty {
            for v in plane {
                sum += Double(v)
                if v < 16 { shadow += 1 }
                if v > 240 { highlight += 1 }
                count += 1
            }
        }
        let mean = count > 0 ? sum / count : 0
        let shadowFrac = count > 0 ? shadow / count : 0
        let highlightFrac = count > 0 ? highlight / count : 0
        let label: String
        if mean < 45 || shadowFrac > 0.5 { label = "underexposed" }
        else if mean > 210 || highlightFrac > 0.2 { label = "overexposed" }
        else { label = "ok" }
        return (label, mean, shadowFrac, highlightFrac)
    }
}

private enum FootageQualityAnalyzer {
    private static let planeWidth = 32
    private static let planeHeight = 18
    private static let burstSeconds = 0.6
    private static let maxBurstFrames = 36
    private static let maxWindows = 200

    private struct SharpnessThresholds {
        let blurry: Double
        let clear: Double
    }

    private struct FrameSample {
        let time: Double
        let sharpness: Double
        let luma: [Float]
        let velocity: Velocity?
    }

    /// Frame-to-frame motion. vx/vy/magnitude are fractions of frame width per second;
    /// residual/visualChange are mean luma change per second (0–1).
    private struct Velocity {
        let vx: Double
        let vy: Double
        let magnitude: Double
        let residual: Double
        let visualChange: Double
    }

    static func analyze(
        url: URL,
        start: Double,
        end: Double,
        windowSeconds: Double,
        fps: Int,
        clip: Clip?
    ) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("analyze_footage_quality: no video track available.")
        }
        let naturalSize = (try? await track.load(.naturalSize)) ?? .zero

        let effectiveWindow = max(windowSeconds, (end - start) / Double(maxWindows))
        var bursts: [(start: Double, end: Double, frames: [FrameSample])] = []
        var cursor = start
        while cursor < end - 0.05 {
            try Task.checkCancellation()
            let windowEnd = min(cursor + effectiveWindow, end)
            let frames = decodeBurst(
                asset: asset, track: track, naturalSize: naturalSize,
                windowStart: cursor, windowEnd: windowEnd
            )
            if frames.count >= 2 {
                bursts.append((cursor, windowEnd, frames))
            }
            cursor = windowEnd
            await Task.yield()
        }
        guard !bursts.isEmpty else {
            throw ToolError("analyze_footage_quality: not enough frames decoded for analysis.")
        }

        let thresholds = sharpnessThresholds(bursts.flatMap(\.frames))
        let windows = bursts
            .map { scoreWindow($0.frames, start: $0.start, end: $0.end, fps: fps, clip: clip, thresholds: thresholds) }
            .sorted { (($0["qualityScore"] as? Double) ?? 0) > (($1["qualityScore"] as? Double) ?? 0) }
        let best = windows
            .filter {
                (($0["isUsable"] as? Bool) ?? false)
                    && (($0["qualityScore"] as? Double) ?? 0) >= 0.65
                    && (($0["durationSeconds"] as? Double) ?? 0) >= 0.5
            }
            .prefix(8)
            .map { window -> [String: Any] in
                var out: [String: Any] = [
                    "startSeconds": window["startSeconds"] ?? 0,
                    "endSeconds": window["endSeconds"] ?? 0,
                    "qualityScore": window["qualityScore"] ?? 0,
                    "stability": window["stability"] ?? "unknown",
                    "stabilityScore": window["stabilityScore"] ?? 0,
                    "clarity": window["clarity"] ?? "unknown",
                ]
                if let a = window["projectStartFrame"] { out["projectStartFrame"] = a }
                if let b = window["projectEndFrame"] { out["projectEndFrame"] = b }
                return out
            }

        return [
            "timeRange": [start, end],
            "frameCount": bursts.reduce(0) { $0 + $1.frames.count },
            "metricNotes": [
                "each window is measured from a burst of consecutive native-fps frames with sub-pixel registration",
                "units: motion/jitter/peakJitter are fractions of frame width per second; visualChange/residual are mean luma change per second",
                "sharpness: normalized edge detail; low values usually mean blur or missed focus",
                "clarity: clear windows are eligible for bestRanges; blurry and soft windows are excluded",
                "motion: global frame-to-frame translation speed (camera pan/subject drift)",
                "jitter: mean deviation of frame-to-frame motion from the window's mean; peakJitter is the worst single kick — high values mean shaky handheld footage",
                "visualChange: residual luma change; high values can mean subject motion, lighting change, or a cut",
                "exposure: underexposed/overexposed from mean brightness + shadow/highlight clipping; gradeable via apply_color, so it flags but doesn't exclude from bestRanges",
            ],
            "sharpnessThresholds": [
                "blurryBelow": thresholds.blurry,
                "clearAtOrAbove": thresholds.clear,
            ],
            "bestRanges": Array(best),
            "windows": windows,
        ]
    }

    /// Decodes a short run of consecutive frames centered in the window. Consecutive
    /// native-fps frames are what makes 4–12 Hz handheld shake visible; sparse sampling aliases it.
    private static func decodeBurst(
        asset: AVURLAsset,
        track: AVAssetTrack,
        naturalSize: CGSize,
        windowStart: Double,
        windowEnd: Double
    ) -> [FrameSample] {
        let duration = min(burstSeconds, windowEnd - windowStart)
        let burstStart = windowStart + max(0, (windowEnd - windowStart - duration) / 2)

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: burstStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let maxDim = max(naturalSize.width, naturalSize.height)
        if maxDim > 960 {
            let scale = 960 / maxDim
            settings[kCVPixelBufferWidthKey as String] = Int(naturalSize.width * scale / 2) * 2
            settings[kCVPixelBufferHeightKey as String] = Int(naturalSize.height * scale / 2) * 2
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var frames: [FrameSample] = []
        var previous: (buffer: CVPixelBuffer, luma: [Float], time: Double)?
        while frames.count < maxBurstFrames, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let luma = lumaPlane(buffer) else { continue }
            let sharpness = LumaPlane.sharpness(luma, width: planeWidth, height: planeHeight)
            var velocity: Velocity?
            if let prev = previous, time - prev.time > 0.001 {
                velocity = measureVelocity(
                    from: prev.buffer, prevLuma: prev.luma,
                    to: buffer, luma: luma,
                    dt: time - prev.time
                )
            }
            frames.append(FrameSample(time: time, sharpness: sharpness, luma: luma, velocity: velocity))
            previous = (buffer, luma, time)
        }
        return frames
    }

    /// Sub-pixel translation via Vision registration, with a coarse grid search fallback
    /// on low-texture frames where registration fails.
    private static func measureVelocity(
        from prev: CVPixelBuffer,
        prevLuma: [Float],
        to current: CVPixelBuffer,
        luma: [Float],
        dt: Double
    ) -> Velocity {
        let width = Double(CVPixelBufferGetWidth(prev))
        var txFrac: Double
        var tyFrac: Double

        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current)
        let handler = VNImageRequestHandler(cvPixelBuffer: prev)
        if (try? handler.perform([request])) != nil,
           let observation = request.results?.first {
            let t = observation.alignmentTransform
            txFrac = Double(t.tx) / width
            tyFrac = Double(t.ty) / width
        } else {
            let shift = gridSearchShift(prevLuma, luma)
            txFrac = Double(shift.dx) / Double(planeWidth)
            tyFrac = Double(shift.dy) / Double(planeWidth)
        }

        let cellDX = Int((txFrac * Double(planeWidth)).rounded())
        let cellDY = Int((tyFrac * Double(planeWidth)).rounded())
        let aligned = shiftedMeanDiff(prevLuma, luma, dx: cellDX, dy: cellDY)
        let raw = LumaPlane.meanDiff(prevLuma, luma)

        let vx = txFrac / dt
        let vy = tyFrac / dt
        return Velocity(
            vx: vx,
            vy: vy,
            magnitude: (vx * vx + vy * vy).squareRoot(),
            residual: Double(aligned) / 255 / dt,
            visualChange: Double(raw) / 255 / dt
        )
    }

    private static func gridSearchShift(_ a: [Float], _ b: [Float]) -> (dx: Int, dy: Int) {
        var bestDX = 0
        var bestDY = 0
        var best = Float.greatestFiniteMagnitude
        for dy in -2...2 {
            for dx in -2...2 {
                let diff = shiftedMeanDiff(a, b, dx: dx, dy: dy)
                if diff < best {
                    best = diff
                    bestDX = dx
                    bestDY = dy
                }
            }
        }
        return (bestDX, bestDY)
    }

    private static func shiftedMeanDiff(_ a: [Float], _ b: [Float], dx: Int, dy: Int) -> Float {
        var diff: Float = 0
        var count: Float = 0
        for y in 0..<planeHeight {
            let by = y + dy
            guard by >= 0 && by < planeHeight else { continue }
            for x in 0..<planeWidth {
                let bx = x + dx
                guard bx >= 0 && bx < planeWidth else { continue }
                diff += abs(a[y * planeWidth + x] - b[by * planeWidth + bx])
                count += 1
            }
        }
        return count > 0 ? diff / count : .greatestFiniteMagnitude
    }

    private static func scoreWindow(
        _ frames: [FrameSample],
        start: Double,
        end: Double,
        fps: Int,
        clip: Clip?,
        thresholds: SharpnessThresholds
    ) -> [String: Any] {
        let velocities = frames.compactMap(\.velocity)
        let sharpness = frames.map(\.sharpness).average
        let motion = velocities.map(\.magnitude).average
        let residual = velocities.map(\.residual).average
        let visualChange = velocities.map(\.visualChange).average

        let meanVX = velocities.map(\.vx).average
        let meanVY = velocities.map(\.vy).average
        let deviations = velocities.map {
            (($0.vx - meanVX) * ($0.vx - meanVX) + ($0.vy - meanVY) * ($0.vy - meanVY)).squareRoot()
        }
        let jitter = deviations.average
        let peakJitter = deviations.max() ?? 0

        let stabilityScore = clamp01(1 - jitter * 8 - max(0, peakJitter - 0.35) * 0.6)
        let staticPenalty = visualChange < 0.05 && motion < 0.02 ? 0.08 : 0
        let highMotionPenalty = motion > 1.0 ? min((motion - 1.0) * 0.15, 0.15) : 0
        let clarity = clarityLabel(sharpness: sharpness, thresholds: thresholds)
        let exposure = exposureMetrics(frames)
        let blurPenalty: Double = clarity == "clear" ? 0 : (clarity == "soft" ? 0.22 : 0.45)
        let quality = clamp01(
            sharpness * 0.45
                + stabilityScore * 0.45
                + min(visualChange * 0.75, 1) * 0.1
                - staticPenalty
                - highMotionPenalty
                - blurPenalty
        )
        let stability = stabilityLabel(stabilityScore: stabilityScore, jitter: jitter, motion: motion)

        var issues: [String] = []
        if stability == "shaky" { issues.append("shaky") }
        if clarity == "blurry" { issues.append("blurry") }
        if clarity == "soft" { issues.append("soft focus") }
        if visualChange < 0.05 && motion < 0.02 { issues.append("static") }
        if motion > 1.1 { issues.append("high motion") }
        if residual > 0.9 { issues.append("large visual change") }
        if exposure.label != "ok" { issues.append(exposure.label) }
        let isUsable = clarity == "clear" && stability != "shaky"

        var out: [String: Any] = [
            "startSeconds": start,
            "endSeconds": end,
            "durationSeconds": end - start,
            "qualityScore": quality,
            "stability": stability,
            "stabilityScore": stabilityScore,
            "clarity": clarity,
            "sharpness": sharpness,
            "motion": motion,
            "jitter": jitter,
            "peakJitter": peakJitter,
            "visualChange": visualChange,
            "exposure": exposure.label,
            "meanLuma": exposure.mean,
            "shadowClipping": exposure.shadow,
            "highlightClipping": exposure.highlight,
            "isUsable": isUsable,
            "issues": issues,
        ]
        if let mapped = projectFrames(start: start, end: end, fps: fps, clip: clip) {
            out["projectStartFrame"] = mapped.start
            out["projectEndFrame"] = mapped.end
        }
        return out
    }

    private static func sharpnessThresholds(_ frames: [FrameSample]) -> SharpnessThresholds {
        let values = frames.map(\.sharpness).sorted()
        let high = percentile(values, 0.9)
        let clear = max(0.34, high * 0.68)
        let blurry = max(0.24, min(clear * 0.72, high * 0.48))
        return SharpnessThresholds(blurry: blurry, clear: clear)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(max(Int((Double(values.count - 1) * p).rounded()), 0), values.count - 1)
        return values[index]
    }

    private static func clarityLabel(sharpness: Double, thresholds: SharpnessThresholds) -> String {
        if sharpness < thresholds.blurry { return "blurry" }
        if sharpness < thresholds.clear { return "soft" }
        return "clear"
    }

    /// Mean brightness (0–255) plus shadow/highlight clipping fractions over the window's frames.
    private static func exposureMetrics(_ frames: [FrameSample]) -> (label: String, mean: Double, shadow: Double, highlight: Double) {
        FootageExposure.classify(planes: frames.map(\.luma).filter { !$0.isEmpty })
    }

    private static func stabilityLabel(stabilityScore: Double, jitter: Double, motion: Double) -> String {
        if stabilityScore < 0.45 || jitter > 0.09 { return "shaky" }
        if motion > 0.35 { return "moving" }
        if stabilityScore > 0.75 { return "stable" }
        return "usable"
    }

    private static func projectFrames(start: Double, end: Double, fps: Int, clip: Clip?) -> (start: Int, end: Int)? {
        guard let clip else { return nil }
        let sourceStart = start * Double(fps)
        let sourceEnd = end * Double(fps)
        let visibleStart = Double(clip.trimStartFrame)
        let visibleEnd = visibleStart + Double(clip.durationFrames) * max(clip.speed, 0.0001)
        let clampedStart = max(sourceStart, visibleStart)
        let clampedEnd = min(sourceEnd, visibleEnd)
        guard clampedEnd > clampedStart else { return nil }
        let timelineStart = Double(clip.startFrame) + (clampedStart - visibleStart) / max(clip.speed, 0.0001)
        let timelineEnd = Double(clip.startFrame) + (clampedEnd - visibleStart) / max(clip.speed, 0.0001)
        return (Int(timelineStart.rounded()), Int(timelineEnd.rounded()))
    }

    /// Box-averaged 32×18 luma from the decoded buffer's Y plane (full-range, 0–255).
    private static func lumaPlane(_ buffer: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let srcWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let srcHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard srcWidth >= planeWidth, srcHeight >= planeHeight else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)

        var out = [Float](repeating: 0, count: planeWidth * planeHeight)
        for cy in 0..<planeHeight {
            let y0 = cy * srcHeight / planeHeight
            let y1 = max(y0 + 1, (cy + 1) * srcHeight / planeHeight)
            for cx in 0..<planeWidth {
                let x0 = cx * srcWidth / planeWidth
                let x1 = max(x0 + 1, (cx + 1) * srcWidth / planeWidth)
                var sum = 0
                for y in y0..<y1 {
                    let row = src + y * stride
                    for x in x0..<x1 {
                        sum += Int(row[x])
                    }
                }
                out[cy * planeWidth + cx] = Float(sum) / Float((y1 - y0) * (x1 - x0))
            }
        }
        return out
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private enum LumaPlane {
    static func sharpness(_ luma: [Float], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0 }
        var total: Float = 0
        var count: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let gx = abs(luma[i + 1] - luma[i - 1])
                let gy = abs(luma[i + width] - luma[i - width])
                total += gx + gy
                count += 1
            }
        }
        return min(Double((total / max(count, 1)) / 55), 1)
    }

    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var diff: Float = 0
        for i in a.indices { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count)
    }
}

private extension Array where Element == Double {
    var average: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
