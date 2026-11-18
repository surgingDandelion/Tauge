import Foundation

/// The languages Tauge ships with.
///
/// The source language is Simplified Chinese, so every user-facing string in
/// the code is written in Chinese and looked up through `L(_:)`. English lives
/// in `Localization/en.json`, keyed by that Chinese source string. Keeping the
/// source string as the key means a missing translation degrades to Chinese
/// instead of crashing or showing a raw identifier.
public enum TaugeLanguage: String, CaseIterable, Sendable, Identifiable {
    case zhHans = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Name shown in the language picker, always written in that language.
    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .english: return "English"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    /// Follow the system preference on first launch: Chinese systems get
    /// Chinese, everything else gets English.
    public static var systemDefault: TaugeLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zhHans : .english
    }
}

/// Process-wide localization table.
///
/// `language` is read on every lookup, so switching it updates strings the next
/// time a view body is evaluated. `AppState` publishes the setting change and
/// rebuilds the AppKit menus, which is enough to refresh the whole UI without
/// restarting the app.
public final class TaugeL10n: @unchecked Sendable {
    public static let shared = TaugeL10n()

    private let lock = NSLock()
    private var _language: TaugeLanguage
    private var english: [String: String] = [:]

    private init() {
        _language = .systemDefault
        english = Self.loadEnglish()
    }

    public var language: TaugeLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _language
        }
        set {
            lock.lock()
            _language = newValue
            lock.unlock()
            NotificationCenter.default.post(name: .taugeLanguageDidChange, object: nil)
        }
    }

    public var locale: Locale { language.locale }

    /// English text for a Chinese source string, or the source string itself
    /// when no translation exists yet.
    public func string(_ key: String) -> String {
        guard language == .english else { return key }
        lock.lock()
        defer { lock.unlock() }
        return english[key] ?? key
    }

    /// Localize a format string and substitute its arguments using the active
    /// language's locale, so decimal separators match the UI language.
    public func formatted(_ format: String, _ arguments: [CVarArg]) -> String {
        guard !arguments.isEmpty else { return string(format) }
        return String(format: string(format), locale: locale, arguments: arguments)
    }

    public func setLanguage(_ language: TaugeLanguage) {
        self.language = language
    }

    /// A snapshot of the loaded Chinese → English table. Used by the self-check
    /// suite to verify placeholder parity; not intended for UI code.
    public var englishTranslations: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return english
    }

    /// Load `en.json` from the ShellXKit resource bundle. A missing bundle must
    /// not take the app down: fall back to the main bundle and then to Chinese.
    private static func loadEnglish() -> [String: String] {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "en", withExtension: "json"),
            Bundle.main.url(forResource: "en", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("ShellX_ShellXKit.bundle/en.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url),
               let table = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                return table
            }
        }
        return [:]
    }
}

public extension Notification.Name {
    /// Posted after `TaugeL10n.shared.language` changes.
    static let taugeLanguageDidChange = Notification.Name("com.shellx.languageDidChange")
}

/// Look up a user-facing string in the active language.
///
/// Every literal that reaches the UI is written as `L("中文")`, which keeps the
/// call sites readable and makes the source language obvious. The key is the
/// exact Chinese string, so `en.json` is a plain Chinese → English map.
public func L(_ key: String) -> String {
    TaugeL10n.shared.string(key)
}

/// Localize a format string (`%@`, `%d`, …) and substitute its arguments.
public func L(_ format: String, _ arguments: CVarArg...) -> String {
    TaugeL10n.shared.formatted(format, arguments)
}
