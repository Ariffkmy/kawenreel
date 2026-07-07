import AppKit
import Foundation

enum AccountTier: String, Decodable, Sendable {
    case none, pro, max

    var isPaid: Bool { self != .none }

    var planLabel: String {
        switch self {
        case .none: return "Free"
        case .pro: return "Pro plan"
        case .max: return "Max plan"
        }
    }

    var upgradeLabel: String {
        switch self {
        case .none: return ""
        case .pro: return "Pro"
        case .max: return "Max"
        }
    }
}

struct AccountUser: Decodable, Sendable {
    let email: String?
    let name: String?
    let image: String?
    let tier: AccountTier
    let currentPeriodEnd: Double?
    let cancelAtPeriodEnd: Bool?
    let spentCreditsThisPeriod: Int?
    let purchasedCredits: Int?

    var displayName: String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var firstName: String? {
        displayName?.split(separator: " ").first.map(String.init)
    }
}

struct AccountPlan: Decodable, Sendable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceUsd: Int
    let discountedMonthlyPriceUsd: Int?
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceUsd: Int {
        hasDiscount ? discountedMonthlyPriceUsd! : monthlyPriceUsd
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceUsd else { return false }
        return discounted < monthlyPriceUsd
    }
}

struct AccountResponse: Decodable, Sendable {
    let user: AccountUser
    let plan: AccountPlan?
}

enum TopOffLimits {
    static let minDollars = 5
    static let maxDollars = 1000
}

/// Kawenreel account state, backed by the Supabase session. Billing (plans,
/// credits, checkout) is inert until Stripe is wired to Supabase — `account`
/// stays nil, so tier is free and the billing UI stays hidden.
@Observable
@MainActor
final class AccountService {
    static let shared = AccountService()

    private(set) var isLoading: Bool = false
    private(set) var isMisconfigured: Bool = false
    private(set) var account: AccountResponse?
    private(set) var availablePlans: [AvailablePlan] = []
    private(set) var lastError: String?
    private(set) var isSigningIn: Bool = false
    private(set) var isBuyingCredits: Bool = false

    var isSignedIn: Bool { SupabaseService.shared.isSignedIn }
    var aiAllowed: Bool { isSignedIn }
    var tier: AccountTier { account?.user.tier ?? .none }
    var isPaid: Bool { tier.isPaid }

    var spentCredits: Int { account?.user.spentCreditsThisPeriod ?? 0 }
    var budgetCredits: Int? {
        guard let user = account?.user else { return nil }
        let tierBudget = account?.plan?.monthlyBudgetCredits ?? 0
        return tierBudget + (user.purchasedCredits ?? 0)
    }

    var remainingCredits: Int { max(0, (budgetCredits ?? 0) - spentCredits) }
    var hasCredits: Bool { remainingCredits > 0 }

    private init() {}

    func configure() {
        Log.account.notice("account configured (supabase)", telemetry: "Account configured")
    }

    func signInWithGoogle() async {
        SignInWindowController.shared.showWindow(nil)
        SignInWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    func signOut() async {
        Log.account.notice("sign out requested", telemetry: "Sign out requested")
        await SupabaseService.shared.signOut()
    }

    // TODO(stripe): reactivate once Stripe checkout is wired to Supabase.
    func subscribe(tier: AccountTier) async {}
    func buyCredits(dollars: Int) {}
    func manageSubscription() async {}

    private struct FeedbackInsert: Encodable {
        let user_id: String?
        let email: String?
        let message: String
        let may_contact: Bool
        let app_version: String
        let os_version: String
        let screenshot_b64: String?
    }

    /// Inserts one row into the Supabase `feedback` table (anon-writable, no reads).
    func sendFeedback(
        message: String,
        email: String?,
        mayContact: Bool,
        screenshotPngBase64: String?,
        appVersion: String,
        osVersion: String
    ) async throws {
        let row = FeedbackInsert(
            user_id: SupabaseService.shared.currentUserId?.uuidString,
            email: email,
            message: message,
            may_contact: mayContact,
            app_version: appVersion,
            os_version: osVersion,
            screenshot_b64: screenshotPngBase64
        )
        var request = URLRequest(url: SupabaseConfig.url.appendingPathComponent("rest/v1/feedback"))
        request.httpMethod = "POST"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        let bearer = SupabaseService.shared.currentAccessToken ?? SupabaseConfig.anonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(row)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "Kawenreel.Feedback",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Feedback upload failed (HTTP \(code))."]
            )
        }
    }
}

// MARK: - Display helpers

extension AccountService {
    var displayPrimaryText: String {
        guard isSignedIn else { return "Signed out" }
        return SupabaseService.shared.currentUser?.email ?? "Signed in"
    }

    var displaySecondaryText: String? { nil }

    var displayInitial: String {
        guard isSignedIn, let email = SupabaseService.shared.currentUser?.email else { return "" }
        return email.first.map { String($0).uppercased() } ?? ""
    }

    func availablePlan(for tier: AccountTier) -> AvailablePlan? {
        availablePlans.first { $0.tier == tier }
    }
}
