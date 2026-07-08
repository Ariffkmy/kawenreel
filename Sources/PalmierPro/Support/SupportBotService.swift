import Foundation

// MARK: - Models

struct ChatRequest: Codable {
    let message: String
    let sessionId: String?
}

struct ChatResponse: Codable {
    let reply: String
    let sessionId: String
}

struct FeedbackRequest: Codable {
    let message: String
    let email: String?
    let category: String?
    let appVersion: String?
    let osVersion: String?
}

struct FeedbackResponse: Codable {
    let status: String
    let message: String
}

struct HealthResponse: Codable {
    let status: String
    let version: String
    let openrouterConfigured: Bool
    let supabaseConfigured: Bool
}

// MARK: - Errors

enum SupportBotError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Server URL is not valid."
        case .networkError(let e): return e.localizedDescription
        case .serverError(let code, let detail): return "Server error (\(code)): \(detail)"
        }
    }
}

// MARK: - Service

final class SupportBotService: Sendable {
    static let shared = SupportBotService()
    static let serverURLDefaultsKey = "support_bot_server_url"
    private static let defaultBaseURL = "http://127.0.0.1:8000"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    var baseURL: String {
        let stored = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey)
        var url = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? Self.defaultBaseURL
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    var isConfigured: Bool { !baseURL.isEmpty }

    func updateBaseURL(_ url: String) {
        UserDefaults.standard.set(
            url.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.serverURLDefaultsKey
        )
    }

    // MARK: - Endpoints

    func checkHealth() async throws -> HealthResponse {
        try await request("/health", method: "GET", body: Optional<ChatRequest>.none)
    }

    func sendMessage(_ text: String, sessionId: String?) async throws -> ChatResponse {
        try await request("/chat", method: "POST", body: ChatRequest(message: text, sessionId: sessionId))
    }

    func sendFeedback(
        message: String,
        email: String? = nil,
        category: String? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil
    ) async throws -> FeedbackResponse {
        try await request("/feedback", method: "POST", body: FeedbackRequest(
            message: message,
            email: email,
            category: category,
            appVersion: appVersion,
            osVersion: osVersion
        ))
    }

    // MARK: - Transport

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw SupportBotError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupportBotError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SupportBotError.serverError(0, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw SupportBotError.serverError(http.statusCode, detail)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: data)
    }
}
