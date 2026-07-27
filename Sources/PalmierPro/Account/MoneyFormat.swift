import Foundation

/// Single source of truth for rendering minor-unit amounts that come back from
/// Stripe and Supabase (plan prices, affiliate commissions, payout thresholds).
enum MoneyFormat {
    static func label(cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        if cents % 100 == 0 { formatter.maximumFractionDigits = 0 }
        return formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? "\(currency.uppercased()) \(Double(cents) / 100)"
    }
}
