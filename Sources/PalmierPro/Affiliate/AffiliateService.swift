import AppKit
import Foundation
import Supabase

/// Affiliate program state for the signed-in user.
///
/// Every mutation is a SECURITY DEFINER RPC: the app can create its own
/// affiliate account, store payout details, and request a payout, but it can
/// never write commissions or read back a stored bank account number — only the
/// last four digits come back, mirrored onto `affiliate_accounts`.
@Observable
@MainActor
final class AffiliateService {
    static let shared = AffiliateService()

    private(set) var isLoading = false
    private(set) var isSavingPayoutDetails = false
    private(set) var summary: AffiliateSummary?
    private(set) var terms: AffiliateProgramTerms = .fallback
    private(set) var lastError: String?
    /// Transient confirmation copy for the pane ("Payout details saved.").
    private(set) var lastStatusMessage: String?

    var isSignedIn: Bool { SupabaseService.shared.isSignedIn }

    private init() {}

    /// Creates the affiliate account if needed, then loads terms and summary.
    /// Safe to call repeatedly; clears state when signed out.
    func refresh() async {
        guard isSignedIn else {
            summary = nil
            lastError = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = SupabaseService.shared.client
            _ = try await client.rpc("ensure_affiliate_account").execute()

            let termRows: [TermsRow] = try await client
                .from("affiliate_program_settings").select().execute().value
            let summaryRows: [SummaryRow] = try await client
                .from("affiliate_summary").select().execute().value

            if let terms = termRows.first?.terms { self.terms = terms }
            summary = summaryRows.first?.summary
            lastError = nil
        } catch {
            lastError = Self.userMessage(for: error)
            Log.affiliate.warning("affiliate refresh failed: \(Log.detail(error))")
        }
    }

    /// Stores payout details. The account number is validated here for immediate
    /// feedback and again in the database, which is what actually enforces it.
    func savePayoutDetails(
        bankName: String,
        accountHolder: String,
        accountNumber: String
    ) async -> Bool {
        guard !isSavingPayoutDetails else { return false }
        if let problem = AffiliatePayoutLimits.validationMessage(
            bankName: bankName, accountHolder: accountHolder, accountNumber: accountNumber
        ) {
            lastError = problem
            lastStatusMessage = nil
            return false
        }

        isSavingPayoutDetails = true
        defer { isSavingPayoutDetails = false }
        do {
            let params = PayoutDetailsParams(
                p_bank_name: bankName.trimmingCharacters(in: .whitespacesAndNewlines),
                p_account_holder: accountHolder.trimmingCharacters(in: .whitespacesAndNewlines),
                p_account_number: AffiliatePayoutLimits.normalizedAccountNumber(accountNumber)
            )
            _ = try await SupabaseService.shared.client
                .rpc("set_affiliate_payout_details", params: params).execute()

            // Never log the account number or holder name.
            Log.affiliate.notice("payout details saved", telemetry: "Affiliate payout details saved")
            lastError = nil
            lastStatusMessage = "Payout details saved."
            await refresh()
            return true
        } catch {
            lastStatusMessage = nil
            lastError = Self.userMessage(for: error)
            Log.affiliate.warning("payout details save failed: \(Log.detail(error))")
            return false
        }
    }

    func copyReferralLink() {
        guard let link = summary?.referralLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        lastStatusMessage = "Referral link copied."
    }

    func clearStatusMessage() {
        lastStatusMessage = nil
    }

    /// Surfaces the database's own validation text (minimum payout, bad account
    /// number) rather than a generic failure.
    private static func userMessage(for error: Error) -> String {
        if let postgrest = error as? PostgrestError { return postgrest.message }
        return error.localizedDescription
    }

    // MARK: - Row shapes (snake_case matches the tables)

    private struct PayoutDetailsParams: Encodable {
        let p_bank_name: String
        let p_account_holder: String
        let p_account_number: String
    }

    private struct TermsRow: Decodable {
        let commission_rate: Double
        let hold_days: Int
        let payout_currency: String

        var terms: AffiliateProgramTerms {
            AffiliateProgramTerms(
                commissionRate: commission_rate,
                holdDays: hold_days,
                currency: payout_currency
            )
        }
    }

    private struct SummaryRow: Decodable {
        let referral_code: String
        let bank_name: String?
        let bank_account_holder: String?
        let bank_account_last4: String?
        let payout_details_updated_at: String?
        let referral_count: Int
        let converted_count: Int
        let clearing_cents: Int
        let ready_cents: Int
        let paid_cents: Int

        var summary: AffiliateSummary {
            AffiliateSummary(
                referralCode: referral_code,
                bankName: bank_name,
                accountHolder: bank_account_holder,
                accountLast4: bank_account_last4,
                payoutDetailsUpdatedAt: payout_details_updated_at.flatMap(Self.date(from:)),
                referralCount: referral_count,
                convertedCount: converted_count,
                clearingCents: clearing_cents,
                readyCents: ready_cents,
                paidCents: paid_cents
            )
        }

        private static func date(from raw: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
    }
}
