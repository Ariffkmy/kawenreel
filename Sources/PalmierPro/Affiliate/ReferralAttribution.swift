import Foundation
import Supabase

/// Captures a referral code before the user has an account and claims it once
/// they sign in.
///
/// A referral arrives as `kawenreel://refer?code=ABCD2345` from the website, or
/// is typed into the Affiliate pane. Either way the code is parked in
/// UserDefaults until there is a session to attach it to, because attribution
/// almost always happens before sign-in.
@MainActor
enum ReferralAttribution {
    private static let pendingCodeKey = "com.kawenreel.app.affiliate.pendingReferralCode"

    static var pendingCode: String? {
        UserDefaults.standard.string(forKey: pendingCodeKey)
    }

    /// True when the URL is a referral link, regardless of whether it carried a
    /// usable code — the caller must not also treat it as an auth callback.
    nonisolated static func isReferralLink(_ url: URL) -> Bool {
        url.scheme == "kawenreel" && url.host == "refer"
    }

    /// Pure parse of a referral deep link. Returns the normalized code, or nil
    /// when the link is not a referral link or carries no usable code.
    nonisolated static func referralCode(from url: URL) -> String? {
        guard isReferralLink(url) else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        return normalized(code)
    }

    /// Returns true when the URL was a referral link (and was consumed).
    @discardableResult
    static func capture(from url: URL) -> Bool {
        guard isReferralLink(url) else { return false }
        guard let normalized = referralCode(from: url) else {
            Log.affiliate.warning("referral link had no usable code")
            return true
        }
        store(normalized)
        Log.affiliate.notice("referral code captured", telemetry: "Referral code captured")
        Task { await claimPendingCode() }
        return true
    }

    static func store(_ code: String) {
        guard let normalized = normalized(code) else { return }
        UserDefaults.standard.set(normalized, forKey: pendingCodeKey)
    }

    static func clearPendingCode() {
        UserDefaults.standard.removeObject(forKey: pendingCodeKey)
    }

    /// Claims a parked code against the current session. Every server outcome is
    /// terminal, so the code is dropped either way; only a transport failure
    /// keeps it for the next attempt.
    @discardableResult
    static func claimPendingCode() async -> ReferralClaimResult? {
        guard let code = pendingCode, SupabaseService.shared.isSignedIn else { return nil }
        let result = await claim(code: code)
        if result != nil { clearPendingCode() }
        return result
    }

    /// Sends a code straight to the server (manual entry in the Affiliate pane).
    /// Returns nil when the request itself failed, so the caller can retry.
    static func claim(code: String) async -> ReferralClaimResult? {
        guard let normalized = normalized(code) else { return .unknownCode }
        do {
            let raw: String = try await SupabaseService.shared.client
                .rpc("claim_referral", params: ["p_code": normalized])
                .execute()
                .value
            let result = ReferralClaimResult(rawValue: raw) ?? .unknownCode
            Log.affiliate.notice(
                "referral claim outcome: \(result.rawValue)",
                telemetry: "Referral claim",
                data: ["outcome": result.rawValue]
            )
            return result
        } catch {
            Log.affiliate.warning("referral claim failed: \(Log.detail(error))")
            return nil
        }
    }

    /// Codes are generated from an unambiguous uppercase alphabet; accept any
    /// case and ignore separators people paste along with them.
    nonisolated private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return (4...16).contains(code.count) ? code : nil
    }
}
