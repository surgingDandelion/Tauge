import SwiftUI
import ShellXKit

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The start page already lists every host, so the sidebar can be
                // collapsed to give a single terminal the whole window.
                if app.settings.sidebarVisible {
                    SidebarView()
                        .frame(width: 240)
                    Divider()
                }
                WorkspaceView()
                    .overlay(alignment: .bottomTrailing) {
                        TransferHUD()
                    }
            }
            Divider()
            StatusBarView()
        }
        .background(Theme.windowBackground)
        // SwiftUI only presents one sheet per view, so every dialog funnels
        // through a single presenter; set(nil) routes to the matching cancel.
        .sheet(item: activeSheet) { sheet in
            switch sheet {
            case .host(let host):
                HostEditorView(host: host).environmentObject(app)
            case .group(let group):
                GroupEditorView(group: group).environmentObject(app)
            case .proxy(let proxy):
                ProxyEditorView(proxy: proxy).environmentObject(app)
            case .keyImporter:
                KeyImporterView().environmentObject(app)
            case .settings:
                SettingsView().environmentObject(app).frame(width: 640, height: 520)
            case .transfers:
                TransferCenterView().environmentObject(app)
            case .palette:
                CommandPaletteView().environmentObject(app)
            case .boardCreate:
                BoardCreateSheet().environmentObject(app)
            case .boardName:
                BoardNameSheet().environmentObject(app)
            case .newSFTPTab:
                NewSFTPTabSheet().environmentObject(app)
            case .termiusImport:
                TermiusImportView().environmentObject(app)
            case .password(let prompt):
                PasswordPromptView(prompt: prompt).environmentObject(app)
            case .hostKey(let prompt):
                HostKeyPromptView(prompt: prompt).environmentObject(app)
            case .conflict(let conflict):
                ConflictPromptView(conflict: conflict).environmentObject(app)
            case .editor(let context):
                EditorView(context: context).environmentObject(app)
            }
        }
        .alert(item: $app.alert) { error in
            Alert(title: Text(error.title),
                  message: Text(error.suggestion.map { error.message + "\n\n" + $0 } ?? error.message),
                  dismissButton: .default(Text(L("好")), action: { app.scheduleTerminalFocus(0.12) }))
        }
    }

    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let prompt = app.passwordPrompt { return .password(prompt) }
                if let prompt = app.hostKeyPrompt { return .hostKey(prompt) }
                if let conflict = app.pendingConflict { return .conflict(conflict) }
                if let context = app.editor { return .editor(context) }
                if let host = app.editingHost { return .host(host) }
                if let group = app.editingGroup { return .group(group) }
                if let proxy = app.editingProxy { return .proxy(proxy) }
                if app.showingKeyImporter { return .keyImporter }
                if app.showingSettings { return .settings }
                if app.showingTransferCenter { return .transfers }
                if app.showingCommandPalette { return .palette }
                if app.showingBoardCreate { return .boardCreate }
                // A draft workspace asks for its name before it can be saved.
                if app.boardNamePrompt != nil { return .boardName }
                if app.showingNewSFTPTab { return .newSFTPTab }
                if app.termiusImport != nil { return .termiusImport }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if app.passwordPrompt != nil { app.cancelPasswordPrompt() }
                if app.hostKeyPrompt != nil { app.resolveHostKeyPrompt(.reject) }
                if app.pendingConflict != nil { app.resolveConflict(nil, applyToAll: false) }
                app.editor = nil
                app.editingHost = nil
                app.editingGroup = nil
                app.editingProxy = nil
                app.showingKeyImporter = false
                app.showingSettings = false
                app.showingTransferCenter = false
                app.showingCommandPalette = false
                app.showingBoardCreate = false
                app.boardNamePrompt = nil
                app.showingNewSFTPTab = false
                app.termiusImport = nil
                // Dismissing a sheet leaves the keyboard on the hosting view;
                // hand it back so the shell accepts typing again.
                app.scheduleTerminalFocus(0.12)
            }
        )
    }
}

/// One active dialog; ordering in `activeSheet` defines priority.
private enum ActiveSheet: Identifiable {
    case host(SSHHost)
    case group(HostGroup)
    case proxy(ProxyConfig)
    case keyImporter
    case settings
    case transfers
    case palette
    case boardCreate
    case boardName
    case newSFTPTab
    case termiusImport
    case password(PasswordPrompt)
    case hostKey(HostKeyPrompt)
    case conflict(PendingConflict)
    case editor(EditorContext)

    var id: String {
        switch self {
        case .host(let host): return "host-" + host.id.uuidString
        case .group(let group): return "group-" + group.id.uuidString
        case .proxy(let proxy): return "proxy-" + proxy.id.uuidString
        case .keyImporter: return "keyImporter"
        case .settings: return "settings"
        case .transfers: return "transfers"
        case .palette: return "palette"
        case .boardCreate: return "boardCreate"
        case .boardName: return "boardName"
        case .newSFTPTab: return "newSFTPTab"
        case .termiusImport: return "termiusImport"
        case .password(let prompt): return "password-" + prompt.id.uuidString
        case .hostKey(let prompt): return "hostKey-" + prompt.id.uuidString
        case .conflict(let conflict): return "conflict-" + conflict.id.uuidString
        case .editor(let context): return "editor-" + context.id.uuidString
        }
    }
}

/// The app palette. Every surface is an explicit light/dark pair instead of an
/// AppKit semantic colour: the semantic ones collapse to pure `#FFFFFF` in light
/// mode (`.underPageBackgroundColor` is a 90%-alpha grey that reads almost black
/// over white), which left the chrome flat and the pane list far too heavy.
/// Keeping our own pairs also lets the light theme carry a slight cool tint and
/// the dark theme a slightly blue green-black, so neither end is "pure black /
/// pure white".
enum Theme {
    /// Canvas behind the workspace and the chrome around terminal panes.
    static let windowBackground = Color(nsColor: windowBackgroundNSColor)
    /// The same canvas as an `NSColor`; AppKit views that paint themselves
    /// (split gutters) used `NSColor.windowBackgroundColor` and left a pure
    /// white / #1E1E1E seam against the tinted canvas.
    static let windowBackgroundNSColor = dynamicNSColor(light: 0xF5F5F8, dark: 0x17181C)
    /// A gentle top-to-bottom wash used by the workspace canvas. It is the only
    /// gradient in the app; everything else stays flat so it keeps the depth.
    static let windowGradient = LinearGradient(
        colors: [dynamic(light: 0xF9F9FB, dark: 0x1B1C21),
                 dynamic(light: 0xF1F1F5, dark: 0x141519)],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Host sidebar, settings sidebar, workspace pane list.
    static let sidebarBackground = dynamic(light: 0xEFEFF3, dark: 0x1B1C21)
    /// Cards, sheets and list panels that sit on top of the window.
    static let panelBackground = dynamic(light: 0xFAFAFC, dark: 0x202127)
    /// Toolbar and tab strip bands.
    static let headerBackground = dynamic(light: 0xF0F0F4, dark: 0x1D1E23)
    /// The title bar of a terminal pane, painted opaquely over the terminal so it
    /// never depends on what the shell is drawing underneath.
    static let paneHeader = dynamic(light: 0xF4F4F8, dark: 0x26272E)
    /// Text fields, search shells and the path bar.
    static let fieldBackground = dynamic(light: 0xFFFFFF, dark: 0x2A2C33)
    /// Raised cards (start page tiles, settings cards).
    static let cardBackground = dynamic(light: 0xFFFFFF, dark: 0x24252B)
    static let cardStroke = dynamic(light: 0xE3E3EA, dark: 0x32333B)
    /// Hairlines, header bars and the path field shell.
    static let separator = dynamic(light: 0xDDDDE4, dark: 0x2C2D34)
    static let shadow = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(isDark ? 0.46 : 0.07)
    })
    static let accent = Color.accentColor
    static let secondary = Color.secondary
    static let danger = Color.red
    static let success = Color.green
    static let warning = Color.orange
    static let rowHover = Color.primary.opacity(0.05)
    static let rowSelection = Color.accentColor.opacity(0.16)

    /// A colour that resolves differently in light and dark mode without going
    /// through AppKit's semantic palette.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    /// Same pair as `dynamic(light:dark:)`, for AppKit drawing code.
    static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(themeHex: isDark ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(themeHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}