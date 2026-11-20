import AppKit
import SwiftTerm

/// Colour schemes for the embedded terminal.
///
/// The PRD asks for six built-in themes plus an iTerm palette importer; the
/// importer is intentionally left out of the MVP, the six built-ins are here.
struct TerminalTheme {
    let name: String
    let background: NSColor
    let foreground: NSColor
    let caret: NSColor
    let ansi: [SwiftTerm.Color]

    /// SwiftTerm expects exactly sixteen entries (normal + bright).
    static func color(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                        green: UInt16((hex >> 8) & 0xFF) * 257,
                        blue: UInt16(hex & 0xFF) * 257)
    }

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(hex & 0xFF) / 255.0,
                alpha: 1)
    }
}

enum TerminalThemeCatalog {
    static let all: [TerminalTheme] = [shellXDark, shellXLight, solarizedDark, solarizedLight, dracula, nord]

    static var names: [String] { all.map(\.name) }

    /// Older builds stored "Tauge Dark"/"Tauge Light"; keep those working so
    /// renaming the product does not reset anyone's terminal colours.
    static func theme(named name: String) -> TerminalTheme {
        if let exact = all.first(where: { $0.name == name }) { return exact }
        switch name {
        case "Tauge Dark": return shellXDark
        case "Tauge Light": return shellXLight
        default: return shellXDark
        }
    }

    /// "Tauge Dark" used to be a near-black slab. The background is now a soft
    /// blue-slate (its ANSI black is lifted with it), which keeps the terminal
    /// distinguishable from the surrounding window chrome instead of looking
    /// like a hole cut into it.
    static let shellXDark = TerminalTheme(
        name: "Tauge Dark",
        background: TerminalTheme.nsColor(0x191C23),
        foreground: TerminalTheme.nsColor(0xDCE2EA),
        caret: TerminalTheme.nsColor(0x79C3F7),
        ansi: [
            TerminalTheme.color(0x23272F), TerminalTheme.color(0xE4686F),
            TerminalTheme.color(0x95C77C), TerminalTheme.color(0xE3BE72),
            TerminalTheme.color(0x62AEEA), TerminalTheme.color(0xC178DE),
            TerminalTheme.color(0x59B6C4), TerminalTheme.color(0xB7BEC9),
            TerminalTheme.color(0x5E6673), TerminalTheme.color(0xFF818C),
            TerminalTheme.color(0xB2E58C), TerminalTheme.color(0xFFD489),
            TerminalTheme.color(0x84C5FF), TerminalTheme.color(0xE39BFF),
            TerminalTheme.color(0x82D9E5), TerminalTheme.color(0xF2F5FA)
        ])

    /// Likewise "Tauge Light" is a warm paper white rather than #FFFFFF, so the
    /// terminal reads as a surface with a tint instead of a blank rectangle.
    static let shellXLight = TerminalTheme(
        name: "Tauge Light",
        background: TerminalTheme.nsColor(0xFBFAF7),
        // Claude Code and other full-screen CLIs use ANSI bright-black for
        // secondary labels and box-drawing accents. Keep the base foreground
        // dark enough that those muted UI elements remain readable on paper.
        foreground: TerminalTheme.nsColor(0x242931),
        caret: TerminalTheme.nsColor(0x0B6BCB),
        ansi: [
            TerminalTheme.color(0x242931), TerminalTheme.color(0xB4232B),
            TerminalTheme.color(0x1F7A3D), TerminalTheme.color(0x8A5A00),
            TerminalTheme.color(0x145FC7), TerminalTheme.color(0x8546A9),
            TerminalTheme.color(0x0B6F79), TerminalTheme.color(0x4B5563),
            TerminalTheme.color(0x4B5563), TerminalTheme.color(0xC23B45),
            TerminalTheme.color(0x197A3C), TerminalTheme.color(0x925F00),
            TerminalTheme.color(0x1B6DE1), TerminalTheme.color(0x9255C0),
            TerminalTheme.color(0x0C7F8C), TerminalTheme.color(0x151A20)
        ])

    static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        background: TerminalTheme.nsColor(0x002B36),
        foreground: TerminalTheme.nsColor(0x839496),
        caret: TerminalTheme.nsColor(0x93A1A1),
        ansi: [
            TerminalTheme.color(0x073642), TerminalTheme.color(0xDC322F),
            TerminalTheme.color(0x859900), TerminalTheme.color(0xB58900),
            TerminalTheme.color(0x268BD2), TerminalTheme.color(0xD33682),
            TerminalTheme.color(0x2AA198), TerminalTheme.color(0xEEE8D5),
            TerminalTheme.color(0x002B36), TerminalTheme.color(0xCB4B16),
            TerminalTheme.color(0x586E75), TerminalTheme.color(0x657B83),
            TerminalTheme.color(0x839496), TerminalTheme.color(0x6C71C4),
            TerminalTheme.color(0x93A1A1), TerminalTheme.color(0xFDF6E3)
        ])

    static let solarizedLight = TerminalTheme(
        name: "Solarized Light",
        background: TerminalTheme.nsColor(0xFDF6E3),
        foreground: TerminalTheme.nsColor(0x657B83),
        caret: TerminalTheme.nsColor(0x586E75),
        ansi: [
            TerminalTheme.color(0x073642), TerminalTheme.color(0xDC322F),
            TerminalTheme.color(0x859900), TerminalTheme.color(0xB58900),
            TerminalTheme.color(0x268BD2), TerminalTheme.color(0xD33682),
            TerminalTheme.color(0x2AA198), TerminalTheme.color(0xEEE8D5),
            TerminalTheme.color(0x002B36), TerminalTheme.color(0xCB4B16),
            TerminalTheme.color(0x586E75), TerminalTheme.color(0x657B83),
            TerminalTheme.color(0x839496), TerminalTheme.color(0x6C71C4),
            TerminalTheme.color(0x93A1A1), TerminalTheme.color(0xFDF6E3)
        ])

    static let dracula = TerminalTheme(
        name: "Dracula",
        background: TerminalTheme.nsColor(0x282A36),
        foreground: TerminalTheme.nsColor(0xF8F8F2),
        caret: TerminalTheme.nsColor(0xF8F8F2),
        ansi: [
            TerminalTheme.color(0x21222C), TerminalTheme.color(0xFF5555),
            TerminalTheme.color(0x50FA7B), TerminalTheme.color(0xF1FA8C),
            TerminalTheme.color(0xBD93F9), TerminalTheme.color(0xFF79C6),
            TerminalTheme.color(0x8BE9FD), TerminalTheme.color(0xF8F8F2),
            TerminalTheme.color(0x6272A4), TerminalTheme.color(0xFF6E6E),
            TerminalTheme.color(0x69FF94), TerminalTheme.color(0xFFFFA5),
            TerminalTheme.color(0xD6ACFF), TerminalTheme.color(0xFF92DF),
            TerminalTheme.color(0xA4FFFF), TerminalTheme.color(0xFFFFFF)
        ])

    static let nord = TerminalTheme(
        name: "Nord",
        background: TerminalTheme.nsColor(0x2E3440),
        foreground: TerminalTheme.nsColor(0xD8DEE9),
        caret: TerminalTheme.nsColor(0x88C0D0),
        ansi: [
            TerminalTheme.color(0x3B4252), TerminalTheme.color(0xBF616A),
            TerminalTheme.color(0xA3BE8C), TerminalTheme.color(0xEBCB8B),
            TerminalTheme.color(0x81A1C1), TerminalTheme.color(0xB48EAD),
            TerminalTheme.color(0x88C0D0), TerminalTheme.color(0xE5E9F0),
            TerminalTheme.color(0x4C566A), TerminalTheme.color(0xD08770),
            TerminalTheme.color(0xA3BE8C), TerminalTheme.color(0xEBCB8B),
            TerminalTheme.color(0x8FBCBB), TerminalTheme.color(0xB48EAD),
            TerminalTheme.color(0x8FBCBB), TerminalTheme.color(0xECEFF4)
        ])
}
