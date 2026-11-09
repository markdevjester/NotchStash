import Foundation

/// Язык интерфейса: как в системе, или выбранный в меню. Русский — для русской системы, иначе английский.
enum Lang {
    static var setting: String { UserDefaults.standard.string(forKey: "language") ?? "auto" }

    static var isRussian: Bool {
        if let forced = ProcessInfo.processInfo.environment["NOTCHSTASH_LANG"] { return forced == "ru" }
        switch setting {
        case "ru": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }
}

/// Строка интерфейса на двух языках.
func L(_ ru: String, _ en: String) -> String { Lang.isRussian ? ru : en }
