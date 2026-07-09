import AppKit

/// Support now lives in a Telegram chat with the support bot.
enum SupportLink {
    // Override with the SupportTelegramBotHandle Info.plist key.
    private static let telegramBotHandle =
        Bundle.main.object(forInfoDictionaryKey: "SupportTelegramBotHandle") as? String
            ?? "hermeztencentbot"

    private static var appURL: URL {
        URL(string: "tg://resolve?domain=\(telegramBotHandle)")!
    }

    // Telegram Web; t.me would bounce to tg:// and fail without the app installed.
    private static var webURL: URL {
        URL(string: "https://web.telegram.org/k/#@\(telegramBotHandle)")!
    }

    @MainActor
    static func open() {
        if NSWorkspace.shared.urlForApplication(toOpen: appURL) != nil {
            NSWorkspace.shared.open(appURL)
        } else {
            NSWorkspace.shared.open(webURL)
        }
    }
}
