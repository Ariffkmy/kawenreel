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
    let monthlyPriceCents: Int
    let currency: String
    let monthlyBudgetCredits: Int?
}

struct AvailablePlan: Decodable, Sendable, Identifiable {
    let tier: AccountTier
    let monthlyPriceCents: Int
    let discountedMonthlyPriceCents: Int?
    let currency: String
    let monthlyBudgetCredits: Int?

    var id: String { tier.rawValue }
    var effectiveMonthlyPriceCents: Int {
        hasDiscount ? discountedMonthlyPriceCents! : monthlyPriceCents
    }
    var hasDiscount: Bool {
        guard let discounted = discountedMonthlyPriceCents else { return false }
        return discounted < monthlyPriceCents
    }

    var priceLabel: String { Self.priceLabel(cents: effectiveMonthlyPriceCents, currency: currency) }
    var originalPriceLabel: String { Self.priceLabel(cents: monthlyPriceCents, currency: currency) }

    static func priceLabel(cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        if cents % 100 == 0 { formatter.maximumFractionDigits = 0 }
        return formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? "\(currency.uppercased()) \(Double(cents) / 100)"
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

/// Kawenreel account state, backed by the Supabase session. Billing state lives
/// in `billing_accounts` (written only by the stripe-webhook edge function) and
/// is refreshed on sign-in and whenever the app returns to the foreground.
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
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AccountService.shared.refreshAccount() }
        }
    }

    /// Fetches the user's billing row + plan catalog. Safe to call repeatedly;
    /// clears state when signed out.
    func refreshAccount() async {
        guard isSignedIn else {
            account = nil
            availablePlans = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseService.shared.client
            let billingRows: [BillingRow] = try await client
                .from("billing_accounts").select().execute().value
            let planRows: [PlanRow] = try await client
                .from("available_plans").select().execute().value

            availablePlans = planRows.map(\.availablePlan)
            let billing = billingRows.first
            let tier = billing.flatMap { AccountTier(rawValue: $0.tier) } ?? .none
            let user = AccountUser(
                email: SupabaseService.shared.currentUser?.email,
                name: nil,
                image: nil,
                tier: tier,
                currentPeriodEnd: billing?.currentPeriodEndEpoch,
                cancelAtPeriodEnd: billing?.cancel_at_period_end,
                spentCreditsThisPeriod: billing?.spent_credits_this_period,
                purchasedCredits: billing?.purchased_credits
            )
            let plan = availablePlans.first { $0.tier == tier }.map {
                AccountPlan(
                    tier: $0.tier,
                    monthlyPriceCents: $0.effectiveMonthlyPriceCents,
                    currency: $0.currency,
                    monthlyBudgetCredits: $0.monthlyBudgetCredits
                )
            }
            account = AccountResponse(user: user, plan: plan)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.account.warning("account refresh failed: \(error.localizedDescription)")
        }
    }

    func signInWithGoogle() async {
        SignInWindowController.shared.showWindow(nil)
        SignInWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    func signOut() async {
        Log.account.notice("sign out requested", telemetry: "Sign out requested")
        await SupabaseService.shared.signOut()
    }

    func subscribe(tier: AccountTier) async {
        guard tier.isPaid else { return }
        await openBillingURL(function: "stripe-checkout", body: ["tier": tier.rawValue])
    }

    func buyCredits(dollars: Int) {
        guard !isBuyingCredits else { return }
        isBuyingCredits = true
        Task {
            await openBillingURL(function: "stripe-checkout", body: ["dollars": dollars])
            isBuyingCredits = false
        }
    }

    func manageSubscription() async {
        await openBillingURL(function: "stripe-portal", body: [:])
    }

    /// Calls a billing edge function and opens the returned Stripe URL in the browser.
    private func openBillingURL(function: String, body: [String: Any]) async {
        guard let token = SupabaseService.shared.currentAccessToken else {
            lastError = "Sign in required."
            return
        }
        do {
            var request = URLRequest(
                url: SupabaseConfig.url.appendingPathComponent("functions/v1/\(function)")
            )
            request.httpMethod = "POST"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let payload = try? JSONDecoder().decode(BillingURLResponse.self, from: data),
                  let url = URL(string: payload.url) else {
                let message = (try? JSONDecoder().decode(BillingErrorResponse.self, from: data))?.error
                throw NSError(
                    domain: "Kawenreel.Billing",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "Billing request failed."]
                )
            }
            lastError = nil
            NSWorkspace.shared.open(url)
        } catch {
            lastError = error.localizedDescription
            Log.account.warning("billing request failed: \(error.localizedDescription)")
        }
    }

    private struct BillingURLResponse: Decodable { let url: String }
    private struct BillingErrorResponse: Decodable { let error: String }

    /// Row shapes for PostgREST reads (snake_case matches the tables).
    private struct BillingRow: Decodable {
        let tier: String
        let current_period_end: String?
        let cancel_at_period_end: Bool
        let purchased_credits: Int
        let spent_credits_this_period: Int

        var currentPeriodEndEpoch: Double? {
            guard let raw = current_period_end else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date.timeIntervalSince1970 }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)?.timeIntervalSince1970
        }
    }

    private struct PlanRow: Decodable {
        let tier: String
        let monthly_price_cents: Int
        let discounted_monthly_price_cents: Int?
        let currency: String
        let monthly_budget_credits: Int?

        var availablePlan: AvailablePlan {
            AvailablePlan(
                tier: AccountTier(rawValue: tier) ?? .none,
                monthlyPriceCents: monthly_price_cents,
                discountedMonthlyPriceCents: discounted_monthly_price_cents,
                currency: currency,
                monthlyBudgetCredits: monthly_budget_credits
            )
        }
    }

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
