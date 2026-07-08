import SwiftUI

/// Floating chat panel for Kawenreel support.
/// Present as a sheet or host in its own window.
struct SupportBotPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = SupportBotViewModel()

    @State private var serverURL = SupportBotService.shared.baseURL
    @State private var showSettings = false
    @State private var showFeedbackComposer = false
    @State private var feedbackText = ""
    @State private var feedbackCategory: FeedbackCategory = .bug
    @State private var feedbackEmail = ""

    private static let loadingRowID = "loading"

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            statusBar
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(width: AppTheme.SupportPanel.width)
        .frame(minHeight: AppTheme.SupportPanel.minHeight, maxHeight: AppTheme.SupportPanel.maxHeight)
        .background(AppTheme.Background.surfaceColor)
        .task { await viewModel.checkServer() }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showFeedbackComposer) { feedbackSheet }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Image(systemName: "message.fill")
                .foregroundStyle(AppTheme.Accent.primary)
                .imageScale(.small)
            Text("Kawenreel Support")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: { viewModel.clearConversation() }) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.sm))
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")

                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: AppTheme.FontSize.sm))
                }
                .buttonStyle(.borderless)
                .help("Settings")

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.bold))
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: AppTheme.SupportPanel.statusDotSize, height: AppTheme.SupportPanel.statusDotSize)
            Text(viewModel.serverStatus.label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
            Spacer()
            if needsConfiguration {
                Button("Configure") { showSettings = true }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(AppTheme.Background.raisedColor.opacity(AppTheme.Opacity.strong))
    }

    private var needsConfiguration: Bool {
        switch viewModel.serverStatus {
        case .notConfigured, .offline: return true
        default: return false
        }
    }

    private var statusColor: Color {
        switch viewModel.serverStatus {
        case .unknown, .checking: return .yellow
        case .online: return AppTheme.Status.successColor
        case .offline, .notConfigured: return AppTheme.Status.errorColor
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.smMd) {
                    ForEach(viewModel.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }

                    if viewModel.isSending {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.leading, AppTheme.Spacing.smMd)
                            Spacer()
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .id(Self.loadingRowID)
                    }
                }
                .padding(AppTheme.Spacing.mdLg)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.isSending) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
            if viewModel.isSending {
                proxy.scrollTo(Self.loadingRowID, anchor: .bottom)
            } else if let last = viewModel.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var canSend: Bool {
        viewModel.serverStatus.isOnline
            && !viewModel.isSending
            && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            TextField("Ask a question…", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.smMd))
                .frame(minHeight: AppTheme.SupportPanel.inputMinHeight)
                .onSubmit { sendMessage() }
                .disabled(!viewModel.serverStatus.isOnline || viewModel.isSending)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(canSend ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)

            Button(action: { showFeedbackComposer = true }) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: AppTheme.FontSize.mdLg))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .buttonStyle(.borderless)
            .help("Report a problem")
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(AppTheme.Background.raisedColor)
    }

    private func sendMessage() {
        guard canSend else { return }
        Task { await viewModel.sendMessage() }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        VStack(spacing: AppTheme.Spacing.lgXl) {
            HStack {
                Text("Server Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { showSettings = false }
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Server URL")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                TextField("http://your-server:8000", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.smMd, design: .monospaced))
            }

            HStack {
                Button("Test Connection") {
                    applyServerURL()
                }
                .controlSize(.small)

                Spacer()

                Button("Save") {
                    applyServerURL()
                    showSettings = false
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.SupportPanel.width, height: AppTheme.SupportPanel.settingsSheetHeight)
    }

    private func applyServerURL() {
        SupportBotService.shared.updateBaseURL(serverURL)
        serverURL = SupportBotService.shared.baseURL
        Task { await viewModel.checkServer() }
    }

    // MARK: - Feedback Sheet

    private var feedbackSheet: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            HStack {
                Text("Send Feedback")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    showFeedbackComposer = false
                    feedbackText = ""
                }
                .controlSize(.small)
            }

            Picker("Category", selection: $feedbackCategory) {
                ForEach(FeedbackCategory.allCases) { category in
                    Text(category.label).tag(category)
                }
            }
            .pickerStyle(.menu)

            TextEditor(text: $feedbackText)
                .font(.system(size: AppTheme.FontSize.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .stroke(AppTheme.Border.subtleColor)
                )
                .frame(height: AppTheme.SupportPanel.feedbackEditorHeight)

            TextField("Email (optional)", text: $feedbackEmail)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: AppTheme.FontSize.sm))

            HStack {
                Spacer()
                Button("Submit") { submitFeedback() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.SupportPanel.width, height: AppTheme.SupportPanel.feedbackSheetHeight)
    }

    private func submitFeedback() {
        let text = feedbackText
        let category = feedbackCategory
        let email = feedbackEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        feedbackText = ""
        feedbackEmail = ""
        showFeedbackComposer = false
        Task {
            await viewModel.sendFeedback(
                message: text,
                category: category,
                email: email.isEmpty ? nil : email
            )
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            if message.role == .user {
                Spacer(minLength: AppTheme.Spacing.xxl)
            } else {
                avatar
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: AppTheme.Spacing.xxs) {
                Text(message.content)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .background(bubbleBackground)
                    .cornerRadius(AppTheme.Radius.md)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.xs)
            }

            if message.role == .bot {
                Spacer(minLength: AppTheme.Spacing.xxl)
            } else {
                avatar
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        switch message.role {
        case .bot:
            Image(systemName: "message.circle.fill")
                .foregroundStyle(AppTheme.Accent.primary)
                .font(.system(size: AppTheme.FontSize.xl))
        case .user:
            Image(systemName: "person.circle.fill")
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .font(.system(size: AppTheme.FontSize.xl))
        case .system:
            EmptyView()
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)
        case .bot: return AppTheme.Background.raisedColor
        case .system: return .clear
        }
    }

    private var textColor: Color {
        message.role == .system ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor
    }
}

#Preview {
    SupportBotPanel()
}
