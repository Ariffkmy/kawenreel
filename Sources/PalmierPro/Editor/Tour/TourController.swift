import AppKit
import Observation

// MARK: - Model

struct TourStep: Equatable {
    enum Kind: Equatable {
        case intro
        case spotlight(TourTarget)
        case outro
    }
    let kind: Kind
    let title: String
    let instruction: String
}

enum TourTarget: Equatable {
    case panel(EditorViewModel.FocusedPanel)
    case element(TourAnchorID)

    /// The panel that must be visible for this target to have a frame.
    var hostPanel: EditorViewModel.FocusedPanel {
        switch self {
        case .panel(let p): return p
        case .element(let id): return id.hostPanel
        }
    }
}

/// Pinpointable controls. Add a case + its `hostPanel`, then tag the view with
/// `.tourAnchor(_:)`. `timelineRuler` is derived (the AppKit ruler has no SwiftUI view).
enum TourAnchorID: Hashable {
    case importButton
    case generateButton
    case generation
    case smartSearch
    case screenshotButton
    case skillsButton
    case timelineRuler
    case supportButton

    var hostPanel: EditorViewModel.FocusedPanel {
        switch self {
        case .importButton, .generateButton, .generation, .smartSearch: return .media
        case .screenshotButton, .supportButton: return .preview
        case .skillsButton: return .agent
        case .timelineRuler: return .timeline
        }
    }
}

/// Weak box so registered anchor views aren't retained by the controller.
final class WeakView {
    weak var value: NSView?
    init(_ value: NSView?) { self.value = value }
}

// MARK: - Controller

@MainActor
@Observable
final class TourController {
    private(set) var stepIndex: Int?
    /// Highlighted region's frame in editor-view coords; set by the split controller.
    var targetFrame: CGRect?
    /// Live backing views for `.element` targets, registered by `.tourAnchor(_:)`.
    @ObservationIgnored var anchorViews: [TourAnchorID: WeakView] = [:]
    /// Bumped when an anchor view lays out, so the split controller recomputes the
    /// frame for controls that appear/animate inside a panel (e.g. the generation panel).
    private(set) var anchorRevision = 0
    func anchorDidLayout() { anchorRevision &+= 1 }
    @ObservationIgnored private weak var editor: EditorViewModel?

    private(set) var steps: [TourStep] = []

    private static let hasRunKey = "tour.hasRun"
    static var hasRun: Bool { UserDefaults.standard.bool(forKey: hasRunKey) }
    static func resetFirstRun() { UserDefaults.standard.removeObject(forKey: hasRunKey) }

    var count: Int { steps.count }

    var spotlightCount: Int {
        steps.reduce(0) { if case .spotlight = $1.kind { return $0 + 1 }; return $0 }
    }

    var currentStep: TourStep? {
        guard let i = stepIndex, steps.indices.contains(i) else { return nil }
        return steps[i]
    }

    func start(in editor: EditorViewModel) {
        UserDefaults.standard.set(true, forKey: Self.hasRunKey)
        self.editor = editor
        steps = Self.makeSteps(editor: editor)
        applyStep(0)
    }

    func advance() {
        guard let i = stepIndex else { return }
        if steps.indices.contains(i + 1) { applyStep(i + 1) } else { end() }
    }

    func back() {
        guard let i = stepIndex, i > 0 else { return }
        applyStep(i - 1)
    }

    func end() {
        stepIndex = nil
        targetFrame = nil
    }

    /// Ensure a spotlight step's host panel is visible
    private func applyStep(_ index: Int) {
        guard let editor, steps.indices.contains(index) else { return }
        editor.maximizedPanel = nil
        if case .spotlight(let target) = steps[index].kind {
            switch target.hostPanel {
            case .media: editor.mediaPanelVisible = true
            case .agent: editor.agentPanelVisible = true
            case .inspector: editor.inspectorPanelVisible = true
            case .timeline, .preview: break
            }
            editor.showGenerationPanel = (target == .element(.generation))
        } else {
            editor.showGenerationPanel = false
        }
        stepIndex = index
    }

    // MARK: - Step list

    private static func makeSteps(editor: EditorViewModel) -> [TourStep] {
        [
            TourStep(kind: .intro, title: "Tutorial",
                     instruction: "Let's take a quick tour of the workspace and what you can do."),
            TourStep(kind: .spotlight(.panel(.media)), title: "Media panel",
                     instruction: "All your footage and assets live here. Import with the button, drag and drop, or copy-paste — and click Generate to create video, image, or audio."),
            TourStep(kind: .spotlight(.panel(.preview)), title: "Preview",
                     instruction: "Play a selected media or the whole timeline."),
            TourStep(kind: .spotlight(.panel(.timeline)), title: "Timeline",
                     instruction: "This is where you edit: video on top, audio below. Right-click a clip for AI features such as upscale, edit, or generate music."),
            TourStep(kind: .spotlight(.panel(.agent)), title: "AI agent",
                     instruction: "Chat with your agent! It can generate content, edit clips, organize your assets, and much more. Start by signing in, or bring your own Anthropic API key."),
            TourStep(kind: .spotlight(.element(.supportButton)), title: "Support",
                     instruction: "Stuck, or found a bug? This opens a Telegram chat with Kawenreel support — our bot answers right away, any time."),
            TourStep(kind: .outro, title: "You're all set",
                     instruction: "Start creating, or explore these to get the most out of Kawenreel."),
        ]
    }
}
