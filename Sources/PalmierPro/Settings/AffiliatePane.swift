import SwiftUI

struct AffiliatePane: View {
    @Bindable private var affiliate = AffiliateService.shared

    @State private var bankName = ""
    @State private var accountHolder = ""
    @State private var accountNumber = ""
    @State private var referralCodeEntry = ""
    @State private var referralEntryMessage: String?
    @State private var isClaimingReferral = false
    @State private var didLoadPayoutFields = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            if affiliate.isLoading && affiliate.summary == nil {
                Text("Loading…")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if !affiliate.isSignedIn {
                signedOutBody
            } else if let summary = affiliate.summary {
                linkSection(summary)
                earningsSection(summary)
                payoutDetailsSection(summary)
                referralEntrySection
            }

            if let message = affiliate.lastStatusMessage {
                statusText(message, color: AppTheme.Status.successColor)
            }
            if let error = affiliate.lastError {
                statusText(error, color: AppTheme.Status.errorColor)
            }
        }
        .task {
            await affiliate.refresh()
            loadPayoutFieldsIfNeeded()
        }
        .onChange(of: affiliate.summary) { _, _ in loadPayoutFieldsIfNeeded() }
    }

    // MARK: - Referral link

    private func linkSection(_ summary: AffiliateSummary) -> some View {
        SettingsGroup(title: "Your referral link") {
            card {
                Text(
                    "Share this link. When someone signs up through it and pays for their "
                    + "first subscription, you earn \(affiliate.terms.ratePercentLabel) of that payment."
                )
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(summary.referralLink.absoluteString)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedSurface(
                            AppTheme.Background.raisedColor,
                            cornerRadius: AppTheme.Radius.sm
                        )

                    Button("Copy") { affiliate.copyReferralLink() }
                        .buttonStyle(.capsule(
                            .secondary,
                            size: .regular,
                            fill: AnyShapeStyle(AppTheme.Background.raisedColor)
                        ))
                        .pointerStyle(.link)
                }

                HStack(spacing: AppTheme.Spacing.lg) {
                    metric("Referrals", value: "\(summary.referralCount)")
                    metric("Subscribed", value: "\(summary.convertedCount)")
                }
                .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }

    // MARK: - Earnings

    private func earningsSection(_ summary: AffiliateSummary) -> some View {
        SettingsGroup(title: "Earnings") {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                card {
                    cardCaption("Owed to you")
                    Text(money(summary.owedCents))
                        .font(.system(
                            size: AppTheme.FontSize.xl,
                            weight: AppTheme.FontWeight.semibold
                        ))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .monospacedDigit()

                    Spacer(minLength: AppTheme.Spacing.xs)

                    Text(payoutFootnote(summary))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                card {
                    cardCaption("Breakdown")
                    if summary.clearingCents > 0 {
                        balanceRow("Clearing", money(summary.clearingCents))
                    }
                    balanceRow("Ready to pay", money(summary.readyCents))
                    balanceRow("Paid", money(summary.paidCents))

                    Spacer(minLength: AppTheme.Spacing.xs)

                    Text("Commission clears \(affiliate.terms.holdDays) days after the payment it came from.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func payoutFootnote(_ summary: AffiliateSummary) -> String {
        guard summary.hasPayoutDetails else {
            return "Add your bank details so we can pay you."
        }
        return "We transfer payouts to your bank account by hand. No request needed."
    }

    // MARK: - Payout details

    private func payoutDetailsSection(_ summary: AffiliateSummary) -> some View {
        SettingsGroup(title: "Bank account") {
            card {
                Text("We transfer approved payouts to this account. Only you and our payments team can see it.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                field("Bank name", text: $bankName, prompt: "Maybank")
                field("Account holder name", text: $accountHolder, prompt: "Full name as per bank")
                field(
                    "Account number",
                    text: $accountNumber,
                    prompt: summary.maskedAccountNumber ?? "Digits only"
                )

                HStack(spacing: AppTheme.Spacing.sm) {
                    Button(affiliate.isSavingPayoutDetails ? "Saving…" : "Save bank details") {
                        Task {
                            let saved = await affiliate.savePayoutDetails(
                                bankName: bankName,
                                accountHolder: accountHolder,
                                accountNumber: accountNumber
                            )
                            if saved { accountNumber = "" }
                        }
                    }
                    .buttonStyle(.capsule(
                        .secondary,
                        size: .regular,
                        fill: AnyShapeStyle(AppTheme.Background.raisedColor)
                    ))
                    .disabled(affiliate.isSavingPayoutDetails || !isPayoutDraftValid)
                    .pointerStyle(.link)

                    if let last4 = summary.accountLast4, accountNumber.isEmpty {
                        Text("Saved: •••• \(last4)")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
        }
    }

    /// The stored number is never returned to the app, so an empty field means
    /// "keep what's saved" only when there is nothing saved yet to keep.
    private var isPayoutDraftValid: Bool {
        AffiliatePayoutLimits.validationMessage(
            bankName: bankName,
            accountHolder: accountHolder,
            accountNumber: accountNumber
        ) == nil
    }

    // MARK: - Being referred

    @ViewBuilder
    private var referralEntrySection: some View {
        SettingsGroup(title: "Referred by someone?") {
            card {
                Text("Enter their code before you subscribe and they'll be credited.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: AppTheme.Spacing.sm) {
                    TextField("", text: $referralCodeEntry, prompt: Text("ABCD2345"))
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .padding(.horizontal, AppTheme.Spacing.smMd)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedSurface(
                            AppTheme.Background.raisedColor,
                            cornerRadius: AppTheme.Radius.sm
                        )
                        .disabled(isClaimingReferral)

                    Button(isClaimingReferral ? "Applying…" : "Apply") {
                        Task { await applyReferralCode() }
                    }
                    .buttonStyle(.capsule(
                        .secondary,
                        size: .regular,
                        fill: AnyShapeStyle(AppTheme.Background.raisedColor)
                    ))
                    .disabled(isClaimingReferral || referralCodeEntry.trimmed.isEmpty)
                    .pointerStyle(.link)
                }

                if let message = referralEntryMessage {
                    Text(message)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func applyReferralCode() async {
        isClaimingReferral = true
        defer { isClaimingReferral = false }
        let result = await ReferralAttribution.claim(code: referralCodeEntry)
        guard let result else {
            referralEntryMessage = "Couldn't reach the server. Try again."
            return
        }
        referralEntryMessage = result.message
        if result == .claimed {
            referralCodeEntry = ""
            ReferralAttribution.clearPendingCode()
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var signedOutBody: some View {
        Text("Sign in to get your referral link and earn \(affiliate.terms.ratePercentLabel) on every referral's first payment.")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)

        Button("Sign in with Google") {
            Task { await AccountService.shared.signInWithGoogle() }
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)
                .disabled(affiliate.isSavingPayoutDetails)
                .accessibilityLabel(label)
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(value)
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .monospacedDigit()
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private func balanceRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(value)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .monospacedDigit()
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cardCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
        .themedSurface(AppTheme.Background.prominentColor, cornerRadius: AppTheme.Radius.mdLg)
    }

    private func money(_ cents: Int) -> String {
        MoneyFormat.label(cents: cents, currency: affiliate.terms.currency)
    }

    /// Seeds the editable fields from the saved details once, so typing is not
    /// overwritten by a later refresh.
    private func loadPayoutFieldsIfNeeded() {
        guard !didLoadPayoutFields, let summary = affiliate.summary else { return }
        didLoadPayoutFields = true
        bankName = summary.bankName ?? ""
        accountHolder = summary.accountHolder ?? ""
        if let pending = ReferralAttribution.pendingCode, referralCodeEntry.isEmpty {
            referralCodeEntry = pending
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
