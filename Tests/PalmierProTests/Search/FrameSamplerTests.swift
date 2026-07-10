import Foundation
import Testing
@testable import PalmierPro

@Suite("FrameSampler")
struct FrameSamplerTests {
    @Test func detectsScenesAtExactCuts() async throws {
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 10),
            .init(rgb: (30, 200, 30), seconds: 10),
            .init(rgb: (30, 30, 220), seconds: 10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var frames: [FrameSampler.Frame] = []
        for try await frame in FrameSampler.frames(url: url, duration: 30) {
            frames.append(frame)
        }

        let shotStarts = frames.filter(\.isNewShot).map(\.time)
        #expect(shotStarts.count == 3, "expected 3 scenes, got starts at \(shotStarts)")
        #expect(frames.first?.isNewShot == true)

        // Dense scan pins boundaries to the actual cut frames.
        #expect(shotStarts.dropFirst().allSatisfy { t in
            abs(t - 10) <= 0.5 || abs(t - 20) <= 0.5
        })

        // Static shots: coverage-floor frames are identical to the shot start
        // and get deduped, so only the boundary frames remain.
        #expect(frames.count == shotStarts.count)
        // Monotonic, no duplicates.
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func gradualChangeKeepsCoverageFrame() async throws {
        // Second scene differs below the cut threshold but above the dedup
        // threshold: no new shot, yet the coverage floor keeps a frame for it.
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (220, 30, 30), seconds: 10),
            .init(rgb: (211, 39, 39), seconds: 10),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        var frames: [FrameSampler.Frame] = []
        for try await frame in FrameSampler.frames(url: url, duration: 20) {
            frames.append(frame)
        }

        #expect(frames.filter(\.isNewShot).count == 1, "gradual change must not count as a cut")
        #expect(frames.contains { !$0.isNewShot && $0.time > 10 }, "changed content should surface via the coverage floor")
    }

    @Test func shortClipGetsOneSample() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (220, 30, 30), seconds: 0.6)])
        defer { try? FileManager.default.removeItem(at: url) }

        var frames: [FrameSampler.Frame] = []
        for try await frame in FrameSampler.frames(url: url, duration: 0.6) {
            frames.append(frame)
        }
        #expect(frames.count == 1)
        #expect(frames.first?.isNewShot == true)
    }
}
