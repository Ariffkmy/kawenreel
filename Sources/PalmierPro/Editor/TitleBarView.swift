import AppKit
import SwiftUI

/// Small pill marking the app as a beta build for testers.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: AppTheme.FontSize.xs, weight: .heavy))
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Capsule().fill(AppTheme.Accent.primary))
            .help("Beta build — thanks for testing")
            .fixedSize()
    }
}

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Button(action: { AppState.shared.showHome() }) {
                Image(systemName: "house")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Go to Home")

            Button(action: { editor.agentPanelVisible.toggle() }) {
                Image(systemName: editor.agentPanelVisible ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.aiGradient)
                    .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            BetaBadge()
        }
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var exportQueue = ExportQueue.shared

    var body: some View {
        let jobs = exportQueue.jobs(for: editor.exportQueueProjectID)
        let activeCount = jobs.count { $0.status.isRunning }
        let waitingCount = jobs.count { $0.status == .waiting }

        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: AppTheme.Spacing.zero)

            Button(action: {
                if let url = URL(string: "https://kawenreel.com/how-to") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("How to use Kawenreel")

            Button(action: { SupportLink.open() }) {
                Image(systemName: "message")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Chat with Kawenreel support")
            .tourAnchor(.supportButton)

            UpdateProjectBadge()

            Button(action: { editor.showExportDialog = true }) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Group {
                        if activeCount > 0 {
                            exportActivityDot
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .offset(y: -1)
                        }
                    }
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    Text("Export")
                }
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .frame(height: AppTheme.IconSize.lg)
                .hoverHighlight()
                .help("Export (⌘E)")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                activeCount == 0 && waitingCount == 0
                    ? "Export"
                    : "Export, \(activeCount) active, \(waitingCount) waiting"
            )

            UserAvatarButton()
        }
    }

    private var exportActivityDot: some View {
        PhaseAnimator([false, true]) { dimmed in
            Circle()
                .fill(AppTheme.Status.warningColor)
                .frame(width: AppTheme.Export.activityDotSize, height: AppTheme.Export.activityDotSize)
                .opacity(dimmed ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
        } animation: { _ in
            .easeInOut(duration: AppTheme.Anim.pulse)
        }
        .accessibilityHidden(true)
    }
}
