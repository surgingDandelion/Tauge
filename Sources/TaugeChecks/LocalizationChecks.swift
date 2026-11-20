import Foundation
import TaugeKit

/// Verifies the runtime localisation layer without launching the UI.
func runLocalizationChecks() {
    let l10n = TaugeL10n.shared
    let original = l10n.language
    defer { l10n.language = original }

    run("l10n.english table loads") {
        let table = l10n.englishTranslations
        expect(table.count > 500, "expected a populated English table, got \(table.count) entries")
        expect(table["新建主机"] != nil, "a core action has a translation")
    }

    run("l10n.switches language live") {
        l10n.language = .english
        expectEqual(L("新建主机"), "New Host", "English lookup")
        l10n.language = .zhHans
        expectEqual(L("新建主机"), "新建主机", "Chinese source string")
        l10n.language = .english
        expectEqual(l10n.locale.identifier, "en", "locale follows language")
    }

    run("l10n.placeholders survive translation") {
        for (key, value) in l10n.englishTranslations {
            expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "empty translation for \(key)")
            let keyTokens = formatTokens(key)
            let valueTokens = formatTokens(value)
            expectEqual(valueTokens, keyTokens, "placeholder parity for '\(key)'")
        }
    }

    run("l10n.formats arguments") {
        l10n.language = .english
        expectEqual(L("%d 个代理", 3), "3 proxies", "integer argument")
        expectEqual(L("删除「%@」？", "web-1"), "Delete “web-1”?", "string argument")
        l10n.language = .zhHans
        expectEqual(L("%d 个代理", 3), "3 个代理", "Chinese formatting")
    }

    run("l10n.english is actually English") {
        // A translation accidentally left as the Chinese key would render the
        // UI half-translated; a few names and acronyms are legitimately equal.
        let allowedSame = Set(["SFTP", "SSH", "HTTP", "SOCKS5", "SOCKS5h", "Termius", "Tauge", "tmux", "vim", "htop", "Ctrl", "Esc", "Tab", "OK"])
        var suspicious: [String] = []
        for (key, value) in l10n.englishTranslations where key == value && !allowedSame.contains(key) {
            suspicious.append(key)
        }
        expect(suspicious.isEmpty, "untranslated entries: \(suspicious.prefix(5).joined(separator: ", "))")
    }
}

private func formatTokens(_ text: String) -> [String] {
    var tokens: [String] = []
    var scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
        if scalars[index] == "%", index + 1 < scalars.count {
            let next = scalars[index + 1]
            if next == "%" {
                index += 2
                continue
            }
            if next == "@" || next == "d" || next == "s" || next == "f" {
                tokens.append("%" + String(next))
                index += 2
                continue
            }
        }
        index += 1
    }
    return tokens
}
