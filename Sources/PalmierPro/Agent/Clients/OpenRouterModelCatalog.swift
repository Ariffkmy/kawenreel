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
            id: "google/gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash-Lite",
            costLevel: "Lowest cost",
            inputPerMTok: 0.10, outputPerMTok: 0.40,
            temperature: 0.1,
            supportsVideo: true,
            note: "Classification, routing, fast tasks"
        ),
        OpenRouterModel(
            id: "google/gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            costLevel: "Low cost",
            inputPerMTok: 0.30, outputPerMTok: 2.50,
            temperature: 0.2,
            supportsVideo: true,
            note: "Best value for video analysis"
        ),
        OpenRouterModel(
            id: "google/gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            costLevel: "Medium–high cost",
            inputPerMTok: 1.25, outputPerMTok: 10.00,
            temperature: 0.3,
            supportsVideo: true,
            note: "Complex scene analysis, large context"
        ),
        OpenRouterModel(
            id: "google/gemini-3.5-flash",
            displayName: "Gemini 3.5 Flash",
            costLevel: "Medium cost",
            inputPerMTok: 1.50, outputPerMTok: 9.00,
            temperature: 0.3,
            supportsVideo: true,
            note: "Multimodal agents, advanced video analysis"
        ),
        OpenRouterModel(
            id: "google/gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash-Lite",
            costLevel: "Low cost",
            inputPerMTok: 0.25, outputPerMTok: 1.50,
            temperature: 0.1,
            supportsVideo: true,
            note: "Lightweight classification and routing"
        ),
        OpenRouterModel(
            id: "qwen/qwen2.5-vl-72b-instruct",
            displayName: "Qwen2.5-VL 72B",
            costLevel: "Low–medium cost",
            inputPerMTok: 0.14, outputPerMTok: 0.28,
            temperature: 0.2,
            supportsVideo: false,
            supportsTools: false,
            note: "Frame analysis; no native video input"
        ),
        OpenRouterModel(
            id: "openai/gpt-4.1-mini",
            displayName: "GPT-4.1 mini",
            costLevel: "Low–medium cost",
            inputPerMTok: 0.40, outputPerMTok: 1.60,
            temperature: 0.2,
            supportsVideo: true,
            note: "Structured editing plans, tool calling"
        ),
        OpenRouterModel(
            id: "openai/gpt-4.1",
            displayName: "GPT-4.1",
            costLevel: "High cost",
            inputPerMTok: 2.50, outputPerMTok: 10.00,
            temperature: 0.1,
            supportsVideo: true,
            note: "Detailed editing instructions"
        ),
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
