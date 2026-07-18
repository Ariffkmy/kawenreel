import Foundation

/// A single agent request's token usage, tagged with the actual model that ran.
/// For OpenRouter this is the full slug (e.g. `anthropic/claude-sonnet-4.5`), so
/// usage is always attributed to the model selected at request time.
struct TokenUsageRecord: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    let provider: String
    let model: String
    var providerMode: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// Persistent, append-only record of agent token usage. Aggregation and credit
/// mapping are intentionally left to callers — this only captures the raw counts.
@Observable
@MainActor
final class TokenUsageTracker {
    static let shared = TokenUsageTracker()

    private(set) var records: [TokenUsageRecord] = []

    private static let storeURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/token-usage.json", isDirectory: false)

    /// Stable per-install id, used to attribute usage to a device in the dashboard.
    nonisolated static let deviceId: String = {
        let key = "kawenreelDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    init() { load() }

    func record(model: String, provider: AgentProvider, providerMode: AgentProviderMode, usage: AgentTokenUsage) {
        guard !usage.isEmpty else { return }
        let record = TokenUsageRecord(
            provider: provider.rawValue,
            model: model,
            providerMode: providerMode.rawValue,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens
        )
        records.append(record)
        save()
        flushIfDue()
    }

    // MARK: Remote reporting (aggregated)

    /// Flush cadence: at most one remote write batch per interval, so a heavy
    /// agent session costs a handful of upserts instead of one insert per request.
    private static let flushInterval: TimeInterval = 30 * 60
    private static let syncedCountKey = "tokenUsageSyncedCount"

    @ObservationIgnored private var lastFlushAttempt: Date = .distantPast
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private func flushIfDue() {
        guard Date().timeIntervalSince(lastFlushAttempt) >= Self.flushInterval else { return }
        flush()
    }

    /// Sums unsynced records by (provider, model) and reports one delta per pair
    /// through the `report_token_usage` RPC. No-op when signed out; the local
    /// JSON store remains the durable record and the watermark only advances on
    /// success, so failed flushes retry with the next batch.
    func flush() {
        guard flushTask == nil else { return }
        guard let token = SupabaseService.shared.currentAccessToken else { return }
        let synced = min(UserDefaults.standard.integer(forKey: Self.syncedCountKey), records.count)
        let pending = Array(records[synced...])
        guard !pending.isEmpty else { return }
        lastFlushAttempt = Date()

        struct GroupKey: Hashable { let provider: String; let model: String }
        var groups: [GroupKey: (requests: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]
        for r in pending {
            var g = groups[GroupKey(provider: r.provider, model: r.model)] ?? (0, 0, 0, 0, 0)
            g.requests += 1
            g.input += r.inputTokens
            g.output += r.outputTokens
            g.cacheRead += r.cacheReadTokens
            g.cacheWrite += r.cacheWriteTokens
            groups[GroupKey(provider: r.provider, model: r.model)] = g
        }

        let newCount = synced + pending.count
        flushTask = Task { @MainActor [weak self] in
            defer { self?.flushTask = nil }
            do {
                for (key, g) in groups {
                    let body: [String: Any] = [
                        "p_provider": key.provider,
                        "p_model": key.model,
                        "p_requests": g.requests,
                        "p_input": g.input,
                        "p_output": g.output,
                        "p_cache_read": g.cacheRead,
                        "p_cache_write": g.cacheWrite,
                    ]
                    var request = URLRequest(
                        url: SupabaseConfig.url.appendingPathComponent("rest/v1/rpc/report_token_usage")
                    )
                    request.httpMethod = "POST"
                    request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                }
                UserDefaults.standard.set(newCount, forKey: Self.syncedCountKey)
            } catch {
                Log.agent.warning("token usage flush failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Aggregates

    var totalTokens: Int { records.reduce(0) { $0 + $1.totalTokens } }

    func totalTokens(forModel model: String) -> Int {
        records.lazy.filter { $0.model == model }.reduce(0) { $0 + $1.totalTokens }
    }

    /// Lifetime token totals keyed by model identifier.
    func totalsByModel() -> [String: Int] {
        records.reduce(into: [:]) { $0[$1.model, default: 0] += $1.totalTokens }
    }

    func reset() {
        records.removeAll()
        UserDefaults.standard.set(0, forKey: Self.syncedCountKey)
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([TokenUsageRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        let snapshot = records
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }
}
