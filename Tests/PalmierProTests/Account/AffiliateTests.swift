import Foundation
import Testing
@testable import PalmierPro

@Suite("Affiliate — payout detail validation")
struct AffiliatePayoutLimitsTests {

    @Test(arguments: [
        ("1234 5678 9012", "123456789012"),
        ("1234-5678-9012", "123456789012"),
        ("  1234567  ", "1234567"),
        ("123456789012", "123456789012"),
    ])
    func normalizationStripsSeparators(raw: String, expected: String) {
        #expect(AffiliatePayoutLimits.normalizedAccountNumber(raw) == expected)
    }

    @Test func acceptsCompleteDetails() {
        #expect(AffiliatePayoutLimits.validationMessage(
            bankName: "Maybank",
            accountHolder: "Siti binti Ahmad",
            accountNumber: "1234 5678 9012"
        ) == nil)
    }

    @Test(arguments: [
        ("", "Siti binti Ahmad", "123456789012"),
        ("M", "Siti binti Ahmad", "123456789012"),
        ("Maybank", "", "123456789012"),
        ("Maybank", "S", "123456789012"),
        ("Maybank", "Siti binti Ahmad", ""),
        ("Maybank", "Siti binti Ahmad", "12345"),
        ("Maybank", "Siti binti Ahmad", "123456789012345678901"),
        ("Maybank", "Siti binti Ahmad", "12345ABCDE"),
    ])
    func rejectsIncompleteOrMalformedDetails(bank: String, holder: String, number: String) {
        #expect(AffiliatePayoutLimits.validationMessage(
            bankName: bank, accountHolder: holder, accountNumber: number
        ) != nil)
    }

    @Test func whitespaceOnlyNamesAreRejected() {
        #expect(AffiliatePayoutLimits.validationMessage(
            bankName: "   ", accountHolder: "   ", accountNumber: "123456789012"
        ) != nil)
    }
}

@Suite("Affiliate — referral link parsing")
struct ReferralAttributionTests {

    @Test func parsesCodeFromDeepLink() {
        let url = URL(string: "kawenreel://refer?code=ABCD2345")!
        #expect(ReferralAttribution.referralCode(from: url) == "ABCD2345")
    }

    @Test func uppercasesAndStripsSeparators() {
        let url = URL(string: "kawenreel://refer?code=abcd-2345")!
        #expect(ReferralAttribution.referralCode(from: url) == "ABCD2345")
    }

    @Test func rejectsCodeOutsideLengthBounds() {
        #expect(ReferralAttribution.referralCode(from: URL(string: "kawenreel://refer?code=AB")!) == nil)
        #expect(ReferralAttribution.referralCode(
            from: URL(string: "kawenreel://refer?code=ABCDEFGHIJKLMNOPQRST")!
        ) == nil)
    }

    @Test func rejectsReferralLinkWithoutCode() {
        #expect(ReferralAttribution.referralCode(from: URL(string: "kawenreel://refer")!) == nil)
    }

    /// An auth callback must stay with the auth handler, or sign-in breaks.
    @Test func authCallbackIsNotAReferralLink() {
        let url = URL(string: "kawenreel://auth-callback#access_token=abc")!
        #expect(!ReferralAttribution.isReferralLink(url))
        #expect(ReferralAttribution.referralCode(from: url) == nil)
    }

    @Test func referralLinkIsRecognisedEvenWithoutUsableCode() {
        #expect(ReferralAttribution.isReferralLink(URL(string: "kawenreel://refer?code=AB")!))
    }
}

@Suite("Affiliate — summary and terms")
struct AffiliateSummaryTests {

    private func summary(
        bankName: String? = "Maybank",
        accountHolder: String? = "Siti binti Ahmad",
        last4: String? = "9012",
        clearing: Int = 0,
        ready: Int = 0,
        paid: Int = 0
    ) -> AffiliateSummary {
        AffiliateSummary(
            referralCode: "ABCD2345",
            bankName: bankName,
            accountHolder: accountHolder,
            accountLast4: last4,
            payoutDetailsUpdatedAt: nil,
            referralCount: 3,
            convertedCount: 1,
            clearingCents: clearing,
            readyCents: ready,
            paidCents: paid
        )
    }

    @Test func referralLinkCarriesTheCode() {
        #expect(summary().referralLink.absoluteString == "https://kawenreel.com/?ref=ABCD2345")
    }

    @Test func payoutDetailsRequireEveryField() {
        #expect(summary().hasPayoutDetails)
        #expect(!summary(bankName: nil).hasPayoutDetails)
        #expect(!summary(bankName: "").hasPayoutDetails)
        #expect(!summary(accountHolder: nil).hasPayoutDetails)
        #expect(!summary(last4: nil).hasPayoutDetails)
    }

    @Test func maskShowsOnlyTheLastFourDigits() {
        let masked = summary().maskedAccountNumber
        #expect(masked == "•••• •••• 9012")
        #expect(!(masked ?? "").contains("5678"))
    }

    @Test func lifetimeSumsEveryStage() {
        #expect(summary(clearing: 100, ready: 200, paid: 400).lifetimeCents == 700)
    }

    /// Money already transferred must not keep showing as owed.
    @Test func owedExcludesWhatWasAlreadyPaid() {
        #expect(summary(clearing: 100, ready: 200, paid: 400).owedCents == 300)
    }

    @Test func ratePercentLabelDropsTrailingZeros() {
        #expect(AffiliateProgramTerms.fallback.ratePercentLabel == "10%")
        let fractional = AffiliateProgramTerms(
            commissionRate: 0.075, holdDays: 30, currency: "myr"
        )
        #expect(fractional.ratePercentLabel == "7.5%")
    }

    @Test func fallbackTermsMatchTheMigrationDefaults() {
        let terms = AffiliateProgramTerms.fallback
        #expect(terms.commissionRate == 0.10)
        #expect(terms.holdDays == 30)
        #expect(terms.currency == "myr")
    }
}

@Suite("Affiliate — referral claim outcomes")
struct ReferralClaimResultTests {

    /// These strings are the contract with `claim_referral`; changing one
    /// silently turns a real outcome into "unknown code".
    @Test(arguments: [
        ("claimed", ReferralClaimResult.claimed),
        ("already_referred", .alreadyReferred),
        ("self_referral", .selfReferral),
        ("unknown_code", .unknownCode),
        ("ineligible", .ineligible),
    ])
    func rawValuesMatchTheDatabaseContract(raw: String, expected: ReferralClaimResult) {
        #expect(ReferralClaimResult(rawValue: raw) == expected)
    }

    @Test func everyOutcomeHasUserFacingCopy() {
        for result in [
            ReferralClaimResult.claimed, .alreadyReferred, .selfReferral, .unknownCode, .ineligible,
        ] {
            #expect(!result.message.isEmpty)
        }
    }
}
