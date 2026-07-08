import SwiftUI

// MARK: - Message Model

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()
}

enum MessageRole: String {
    case user
    case bot
    case system
}

enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug
    case missingCapability = "missing_capability"
    case confusingUX = "confusing_ux"
    case failure
    case suggestion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bug: return "Bug"
        case .missingCapability: return "Missing Capability"
        case .confusingUX: return "Confusing UX"
        case .failure: return "Failure"
        case .suggestion: return "Suggestion"
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class SupportBotViewModel {
    private(set) var messages: [ChatMessage] = []
    var inputText: String = ""
    private(set) var isSending = false
    private(set) var serverStatus: ServerStatus = .unknown

    private var sessionId: String?
    private let service = SupportBotService.shared

    private static let greeting = "Ask a question about Kawenreel, or report a problem."

    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let osVersion: String = {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        return "\(info.majorVersion).\(info.minorVersion).\(info.patchVersion)"
    }()

    enum ServerStatus: Equatable {
        case unknown
        case checking
        case online
        case offline(String)
        case notConfigured

        var label: String {
            switch self {
            case .unknown, .checking: return "Connecting…"
            case .online: return "Connected"
            case .offline(let detail): return "Offline: \(detail)"
            case .notConfigured: return "Not configured"
            }
        }

        var isOnline: Bool { self == .online }
    }

    init() {
        messages.append(ChatMessage(role: .system, content: Self.greeting))
    }

    // MARK: - Health Check

    func checkServer() async {
        guard service.isConfigured else {
            serverStatus = .notConfigured
            return
        }

        serverStatus = .checking
        do {
            let health = try await service.checkHealth()
            serverStatus = health.openrouterConfigured ? .online : .offline("API key not set")
        } catch {
            serverStatus = .offline(error.localizedDescription)
        }
    }

    // MARK: - Send Message

    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, service.isConfigured else { return }

        inputText = ""
        isSending = true
        defer { isSending = false }

        messages.append(ChatMessage(role: .user, content: text))

        do {
            let response = try await service.sendMessage(text, sessionId: sessionId)
            sessionId = response.sessionId
            messages.append(ChatMessage(role: .bot, content: response.reply))
        } catch {
            messages.append(ChatMessage(
                role: .system,
                content: "Couldn't reach the server. \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Feedback

    func sendFeedback(message: String, category: FeedbackCategory, email: String? = nil) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            let response = try await service.sendFeedback(
                message: text,
                email: email,
                category: category.rawValue,
                appVersion: appVersion,
                osVersion: osVersion
            )
            messages.append(ChatMessage(role: .system, content: response.message))
        } catch {
            messages.append(ChatMessage(
                role: .system,
                content: "Couldn't send feedback. \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Clear

    func clearConversation() {
        messages = [ChatMessage(role: .system, content: Self.greeting)]
        sessionId = nil
    }
}
