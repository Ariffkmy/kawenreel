import Foundation

/// Program terms, mirrored from `affiliate_program_settings` so the pane always
/// states the rate and threshold the server will actually enforce.
struct AffiliateProgramTerms: Sendable, Equatable {
    let commissionRate: Double
    /// Advisory only: commission inside this window is still within the refund
    /// period, so it is shown as clearing. Payouts are made by hand.
    let holdDays: Int
    let currency: String

    /// Used only until the first successful fetch; matches the migration defaults.
    static let fallback = AffiliateProgramTerms(
        commissionRate: 0.10,
        holdDays: 30,
        currency: "myr"
    )

    var ratePercentLabel: String {
        let percent = commissionRate * 100
        return percent == percent.rounded()
            ? "\(Int(percent))%"
            : String(format: "%.1f%%", percent)
    }
}

/// One read of `affiliate_summary`: the affiliate's code, payout details, and
/// earnings split by lifecycle stage.
struct AffiliateSummary: Sendable, Equatable {
    let referralCode: String
    let bankName: String?
    let accountHolder: String?
    let accountLast4: String?
    let payoutDetailsUpdatedAt: Date?
    let referralCount: Int
    let convertedCount: Int
    /// Earned but still inside the refund window.
    let clearingCents: Int
    /// Matured and awaiting a manual transfer.
    let readyCents: Int
    let paidCents: Int

    var hasPayoutDetails: Bool {
        guard let last4 = accountLast4, !last4.isEmpty else { return false }
        return !(bankName ?? "").isEmpty && !(accountHolder ?? "").isEmpty
    }

    var maskedAccountNumber: String? {
        accountLast4.map { "•••• •••• \($0)" }
    }

    /// Everything earned and not reversed, whether or not it has been sent yet.
    var lifetimeCents: Int { clearingCents + readyCents + paidCents }

    /// Owed but not yet transferred.
    var owedCents: Int { clearingCents + readyCents }

    var referralLink: URL {
        var components = URLComponents(string: "https://kawenreel.com/")!
        components.queryItems = [URLQueryItem(name: "ref", value: referralCode)]
        return components.url!
    }
}

/// Outcome of `claim_referral`. Stable machine values; UI copy is mapped in the view.
enum ReferralClaimResult: String, Sendable {
    case claimed
    case alreadyReferred = "already_referred"
    case selfReferral = "self_referral"
    case unknownCode = "unknown_code"
    case ineligible

    /// Every outcome is terminal for a given code — none become claimable later,
    /// so a stored pending code is dropped once any of these comes back.
    var message: String {
        switch self {
        case .claimed: return "Referral applied."
        case .alreadyReferred: return "Your account is already linked to a referrer."
        case .selfReferral: return "You can't use your own referral code."
        case .unknownCode: return "That referral code doesn't exist."
        case .ineligible: return "Referral codes can only be applied before you subscribe."
        }
    }
}

/// Payout-detail limits. The database enforces the same bounds in
/// `set_affiliate_payout_details`; these exist so the UI can disable Save and
/// explain the problem before a round trip.
enum AffiliatePayoutLimits {
    static let bankNameLength = 2...80
    static let accountHolderLength = 2...120
    static let accountNumberDigits = 6...20

    /// Strips the separators people paste from a bank statement.
    static func normalizedAccountNumber(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != "-" }
    }

    static func validationMessage(
        bankName: String,
        accountHolder: String,
        accountNumber: String
    ) -> String? {
        let bank = bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        let holder = accountHolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = normalizedAccountNumber(accountNumber)

        guard bankNameLength.contains(bank.count) else {
            return "Enter the bank name."
        }
        guard accountHolderLength.contains(holder.count) else {
            return "Enter the account holder's full name."
        }
        guard number.allSatisfy(\.isNumber), accountNumberDigits.contains(number.count) else {
            return "Account number must be \(accountNumberDigits.lowerBound)–"
                + "\(accountNumberDigits.upperBound) digits."
        }
        return nil
    }
}
