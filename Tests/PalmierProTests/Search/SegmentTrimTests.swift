import Foundation
import Testing
@testable import PalmierPro

/// Dragging a search "moment" places a clip trimmed to the segment.
@MainActor
@Suite("Segment trim placement")
struct SegmentTrimTests {
    private func editor(fps: Int = 30) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(fps: fps, tracks: [Fixtures.videoTrack()])
        return e
    }

    private func asset() -> MediaAsset {
        MediaAsset(url: URL(fileURLWithPath: "/tmp/a.mov"), type: .video, name: "a", duration: 100)
    }

    @Test func clipDurationFromSegment() {
        let e = editor()
        // No-segment video drops are capped at maxDraggedClipSeconds (4s @ 30fps).
        #expect(e.clipDurationFrames(for: asset(), segment: nil) == 120)
        #expect(e.clipDurationFrames(for: asset(), segment: 10...14) == 120) // 4s window
        // An explicit segment is honored as-is, even past the cap.
        #expect(e.clipDurationFrames(for: asset(), segment: 10...20) == 300)
    }

    @Test func placesTrimmedClip() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 10...14])
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimStartFrame == 300)   // 10s × 30, head trim
        #expect(clip?.trimEndFrame == 2580)    // tail trim: 3000 total − 300 head − 120 visible
        #expect(clip?.durationFrames == 120)
    }

    @Test func noSegmentPlacesCappedClipWithHeadroom() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0)
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimStartFrame == 0)
        // Capped at 4s; the untrimmed source remains as headroom for extending.
        #expect(clip?.durationFrames == 120)
    }

    /// Fence-post: a segment ending exactly at the asset end trims nothing off
    /// the tail, so trimEndFrame is 0 (and the clip references the full source).
    @Test func segmentAtAssetEndStaysInBounds() {
        let e = editor()
        let a = asset()
        e.createClips(from: [a], trackIndex: 0, startFrame: 0, segments: [a.id: 96...100])
        let clip = e.timeline.tracks[0].clips.first
        #expect(clip?.trimEndFrame == 0)            // ends at asset end → no tail trim
        #expect(clip?.sourceDurationFrames == 3000) // references the whole 100s × 30 source
    }
}
