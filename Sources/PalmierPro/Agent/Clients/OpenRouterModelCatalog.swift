import Foundation

/// OpenRouter chat models offered in the agent panel.
struct OpenRouterModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let costLevel: String
    let inputPerMTok: Double
    let outputPerMTok: Double
    let temperature: Double
    let supportsVideo: Bool
    /// The agent requires tool calling; models without a tool-capable
    /// OpenRouter endpoint can't be selected for chat.
    var supportsTools: Bool = true
    let note: String

    var isDefault: Bool { id == OpenRouterModelCatalog.defaultModelID }
}

enum OpenRouterModelCatalog {
    static let defaultModelID = OpenAICompatibleConfig.defaultModel

    static let all: [OpenRouterModel] = [
        OpenRouterModel(
            id: "anthropic/claude-sonnet-4.6",
            displayName: "Claude Sonnet 4.6",
            costLevel: "High cost",
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            temperature: 0.2,
            supportsVideo: false,
            note: "Recommended Claude; editing plans, EDLs, frames + transcript"
        ),
        OpenRouterModel(
            id: "anthropic/claude-sonnet-4.5",
            displayName: "Claude Sonnet 4.5",
            costLevel: "High cost",
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            temperature: 0.2,
            supportsVideo: false,
            note: "Claude fallback; frames + transcript"
        ),
        OpenRouterModel(
            id: "anthropic/claude-sonnet-4",
            displayName: "Claude Sonnet 4",
            costLevel: "High cost",
            inputPerMTok: 3.00, outputPerMTok: 15.00,
            temperature: 0.2,
            supportsVideo: false,
            note: "Claude fallback; frames + transcript"
        ),
    ]

    static func model(id: String) -> OpenRouterModel? {
        all.first { $0.id == id }
    }

    static func displayName(for id: String) -> String {
        model(id: id)?.displayName ?? id
    }
}
