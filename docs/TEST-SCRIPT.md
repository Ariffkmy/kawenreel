# Kawenreel — Manual Test Script

Full pre-release QA pass. Run top to bottom on a clean Mac for release candidates
(sections 1–2 require the notarized DMG); sections 3+ can be run from a dev build
(`swift run`) for day-to-day checks.

Prep: a folder with 6–10 wedding video clips (mixed quality: some shaky/blurry
starts), 2–3 photos, one music MP3, and one clip with clear speech.

Legend: ☐ pass · ✗ fail (note the section number in the bug report)

---

## 1. Install & first launch (clean Mac)

- ☐ Copy `PalmierPro.dmg` to a Mac that has never run Kawenreel. Double-click:
  DMG mounts, shows the app with an Applications shortcut.
- ☐ Drag to Applications, launch. **No Gatekeeper warning** appears (app is
  notarized). If a "downloaded from the internet" prompt appears, it has an
  **Open** button — never "move to bin".
- ☐ First launch shows onboarding, then Home. No sign-in wall.
- ☐ Quit and relaunch: onboarding does not repeat; Home opens directly.

## 2. Auto-update (Sparkle)

- ☐ Kawenreel menu → **Check for Updates…** runs without error (with no newer
  version in the appcast it reports "up to date").
- ☐ After a newer release is published: update badge appears in the title bar;
  clicking it shows release notes and installs + relaunches successfully.

## 3. Accounts (sign-in is optional)

- ☐ Kawenreel menu shows **Sign In…** enabled and **Sign Out** greyed out.
- ☐ Sign In… opens the sign-in window; the window is closable (no forced gate).
- ☐ Create account with a real email: app switches to "Confirm your email" and a
  confirmation email arrives. Sign-in **fails** before clicking the link,
  succeeds after.
- ☐ After sign-in the window closes itself; menu now shows Sign Out enabled.
- ☐ Sign Out works; app remains fully usable while signed out.

## 4. Projects & timelines

- ☐ Home → New Project creates and opens a project; File → Save writes a
  `.palmier` package; reopening it restores everything.
- ☐ File → Open… works with a `.palmier` from another location.
- ☐ Create a second timeline in the project; switch between timeline tabs —
  playhead/zoom/scroll are remembered per timeline.
- ☐ Rename a timeline; the tab updates.
- ☐ Drag one timeline into another as a clip (nesting): shows as a single
  `sequence` clip; editing the child timeline updates the nest in the parent
  preview.

## 5. Media import & library

- ☐ Drag a folder of clips into the media panel: all import, folder structure
  preserved; thumbnails and durations appear as processing completes.
- ☐ Import via toolbar/file picker works for video, audio, and images.
- ☐ Unsupported file (e.g. `.txt`) is rejected with a clear message.
- ☐ Google Drive import (requires sign-in): sheet lists folder contents;
  selected items download and appear in the library.
- ☐ Create folder, rename, move assets between folders, delete an asset
  (its timeline clips are removed too, with a warning).
- ☐ Media panel tabs all open: Media, Captions, Audio, Fonts.
- ☐ Fonts tab: import a `.ttf` — it appears and is selectable in text styling.

## 6. Timeline editing

- ☐ Drag a long video to the timeline: clip is **capped at 4 seconds** with the
  rest kept as trim headroom (drag its edge to extend). Audio drops keep full
  length.
- ☐ Trim clip edges; split at playhead; ripple-delete a range closes the gap.
- ☐ Move clips within/between tracks; linked audio follows video moves.
- ☐ Speed change (0.5×/2×) alters duration and pitch-corrected audio plays.
- ☐ Fade in/out handles work on video (opacity) and audio (volume).
- ☐ Undo (⌘Z) and redo (⇧⌘Z) work across every operation above, including
  agent-made edits.
- ☐ Track controls: mute, hide, resize height, reorder (video stays above
  audio zone), sync-lock behavior on ripple edits.
- ☐ Copy/paste clips, including across timelines.

## 7. Preview, compositing & color

- ☐ Playback is smooth at 1080p; scrubbing follows the playhead.
- ☐ Transform (move/scale/rotate/flip), crop with aspect locks, and opacity all
  render live; snapping to canvas edges/center works with guides shown.
- ☐ Keyframes: animate position/scale/opacity/crop/volume; curves editable in
  the keyframes panel.
- ☐ Blend modes on an upper clip render correctly.
- ☐ Letterbox: set a ratio (e.g. 2.39:1) — bars render in preview **and** in
  export.
- ☐ Rulers + custom guides toggle from the View menu and persist.
- ☐ **Adjustment layer**: add above footage, apply a color grade — everything
  below is graded, clips above are not; toggling the layer off restores.
- ☐ Inspector Adjust tab: exposure/contrast/saturation, wheels, curves, hue
  curves, LUT load — all live-update and survive save/reload.

## 8. Text & captions

- ☐ Add a text overlay; edit content, font (incl. imported), size, color,
  outline, background; move/scale it on canvas.
- ☐ Text animation presets play in preview and export.
- ☐ Auto-captions on a speech clip: caption clips appear word-timed on their own
  track; active-word highlight animates.
- ☐ Restyle the whole caption group at once (font/color/position).
- ☐ Edit one caption's text; split words stay in sync.

## 9. Audio tools

- ☐ Audio tab (media panel): speech tools visible; music library section works.
- ☐ Per-clip volume + dB keyframes; meters respond during playback.
- ☐ **Denoise** a noisy voice clip: background noise drops at default strength;
  disable restores the original.
- ☐ **Remove silence / dead air**: pauses are cut and gaps closed; dead-air
  markers can be toggled in Settings.
- ☐ **Beat detection**: run on the music track; cuts snapped to beats land on
  the beat audibly.
- ☐ **Audio sync**: two clips of the same moment (camera + external mic) align
  by waveform; **timecode sync** aligns clips carrying source timecode.

## 10. Search

- ☐ Visual search ("bride walking outdoors") returns relevant moments after
  indexing completes; dragging a hit places exactly that segment (no 4 s cap on
  explicit segments).
- ☐ Spoken search for a phrase that was said finds the right clip + time.

## 11. AI agent

Signed-out, no key:
- ☐ Agent panel explains chat is unavailable and points to sign-in / own key —
  no crash, no silent failure.

Signed-in (proxy):
- ☐ Send "what's on my timeline?" — answer streams via the Kawenreel proxy and
  reflects the real project.
- ☐ Write in Malay — the agent replies in Malay.
- ☐ "Cut this video to the beat of the music" — beats analyzed, cuts land on
  beats, response is 1–2 sentences (no play-by-play narration).
- ☐ "Trim the shaky start off this clip" — footage-quality analysis trims to a
  stable range.
- ☐ Set a style reference ("edit like this video" on a library asset), then ask
  for a grade — color match applies via an adjustment layer.
- ☐ Wedding flow: with nikah footage, "buatkan highlight" assembles in ceremony
  order, akad audio kept audible, no music over the lafaz/"sah".
- ☐ Ask "what model are you?" — it answers as the Kawenreel assistant, never
  naming the underlying provider.
- ☐ Every agent edit is undoable with ⌘Z.
- ☐ After a signed-in session, `token_usage_daily` in Supabase gains/updates a
  row for today (checks the aggregated usage pipeline; allow up to 30 min or
  relaunch to force a flush).

## 12. Export

- ☐ Default export (H.264, Match Timeline) renders in background; system
  notification on completion; file plays in QuickTime with correct picture,
  audio, captions, grades, and letterbox.
- ☐ H.265 and ProRes options render; resolution presets produce the right sizes.
- ☐ Export with an adjustment layer present shows the "won't transport" warning
  for XML/FCPXML.
- ☐ XML (Premiere) and FCPXML (Resolve target) import into their editors with
  correct clip timing.
- ☐ `.palmier` package export reopens as a self-contained project on another
  Mac.

## 13. Feedback & telemetry

- ☐ Title bar feedback button: submit a message (with screenshot attached) —
  a new row appears in the Supabase `feedback` table.
- ☐ Settings → Privacy: telemetry toggle off is respected (no Sentry traffic
  after relaunch).

## 14. Settings & misc

- ☐ All Settings panes open and persist changes: Account, Agent, Models,
  Notifications, Privacy, Skills, Storage, Style.
- ☐ Keyboard shortcuts window (Help menu) opens; a sample of listed shortcuts
  works.
- ☐ MCP: an external MCP client (e.g. Claude Code) connects to the running app
  at `127.0.0.1:19789`, lists tools, and can `get_timeline`.
- ☐ Network loss: with Wi-Fi off, the app warns but local editing, playback,
  and export still work.
- ☐ App Nap / sleep during a background export: export completes or fails
  loudly — never hangs silently.

---

### Sign-off

| Build | Date | Tester | Result |
|-------|------|--------|--------|
|       |      |        |        |
