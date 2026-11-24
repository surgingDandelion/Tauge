import SwiftUI
import TaugeKit

struct ContentView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var presentedConflictID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            AppChromeHeader()
            WorkspaceView()
                .overlay(alignment: .bottomTrailing) { TransferHUD() }
            Divider()
            StatusBarView()
        }
        .background(Theme.windowBackground)
        // Quick open is an overlay, not a sheet: ⌘K has to feel like Spotlight
        // rather than a modal card that drags the window with it.
        .overlay {
            if app.showingCommandPalette {
                QuickOpenView()
                    .environmentObject(app)
                    .transition(.opacity)
            }
        }
        // SwiftUI only presents one sheet per view, so every dialog funnels
        // through a single presenter; set(nil) routes to the matching cancel.
        .sheet(item: activeSheet, onDismiss: conflictSheetDidDismiss) { sheet in
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
                SettingsView(onClose: { app.showingSettings = false }).environmentObject(app)
            case .transfers:
                TransferCenterView().environmentObject(app)
            case .boardCreate:
                BoardCreateSheet().environmentObject(app)
            case .board(let board):
                BoardEditorView(board: board).environmentObject(app)
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
                ConflictPromptView(conflict: conflict)
                    .environmentObject(app)
                    .onAppear {
                        if app.conflictSheetDidAppear(id: conflict.id) {
                            presentedConflictID = conflict.id
                        }
                    }
            case .commandConfirmation(let prompt):
                CommandConfirmationPromptView(prompt: prompt).environmentObject(app)
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
                if app.conflictSheetIsClosing { return nil }
                if let conflict = app.pendingConflict, conflict.id == presentedConflictID {
                    return .conflict(conflict)
                }
                if let prompt = app.passwordPrompt { return .password(prompt) }
                if let prompt = app.hostKeyPrompt { return .hostKey(prompt) }
                if let conflict = app.pendingConflict { return .conflict(conflict) }
                if let prompt = app.commandConfirmationPrompt { return .commandConfirmation(prompt) }
                if let context = app.editor { return .editor(context) }
                if let host = app.editingHost { return .host(host) }
                if let group = app.editingGroup { return .group(group) }
                if let proxy = app.editingProxy { return .proxy(proxy) }
                if let board = app.editingBoard { return .board(board) }
                if app.showingKeyImporter { return .keyImporter }
                if app.showingSettings { return .settings }
                if app.showingTransferCenter { return .transfers }
                if app.showingBoardCreate { return .boardCreate }
                // A draft workspace asks for its name before it can be saved.
                if app.boardNamePrompt != nil { return .boardName }
                if app.showingNewSFTPTab { return .newSFTPTab }
                if app.termiusImport != nil { return .termiusImport }
                return nil
            },
            set: { newValue in
                guard newValue == nil, presentedConflictID == nil else { return }
                if app.passwordPrompt != nil { app.cancelPasswordPrompt() }
                if app.hostKeyPrompt != nil { app.resolveHostKeyPrompt(.reject) }
                if app.commandConfirmationPrompt != nil { app.resolveCommandConfirmation(false) }
                app.editor = nil
                app.editingHost = nil
                app.editingGroup = nil
                app.editingBoard = nil
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

    private func conflictSheetDidDismiss() {
        guard let id = presentedConflictID else { return }
        presentedConflictID = nil
        app.conflictSheetDidDismiss(id: id)
        app.scheduleTerminalFocus(0.12)
    }
}

private struct AppChromeHeader: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var windowChrome = MainWindowChrome()
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            WindowControlStrip(isFullScreen: windowChrome.isFullScreen,
                               isWindowActive: windowChrome.isWindowActive,
                               onClose: windowChrome.close,
                               onMinimize: windowChrome.minimize,
                               onToggleFullScreen: windowChrome.toggleFullScreen)
            WindowDragRegion(onAttach: windowChrome.attach(to:))
                .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            if app.isStartPageSelected { groupFilter }
            HStack(spacing: 3) {
                chromeButton("magnifyingglass", title: L("全局搜索"), label: L("搜索"),
                             selected: app.showingCatalogSearch) {
                    app.showCatalogSearch(initialQuery: app.isStartPageSelected && !app.startPageQuery.isEmpty
                                          ? app.startPageQuery : nil)
                }
                chromeButton("gearshape", title: L("设置…")) { app.showingSettings = true }
                actionsMenu
            }
            .padding(3)
            .background(Theme.fieldBackground.opacity(0.85),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator, lineWidth: 1))
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Theme.titleBarGradient)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .onReceive(MainWindowChrome.changes, perform: windowChrome.windowDidChange)
    }

    private var groupFilter: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            TextField(L("筛选当前分组…"), text: $app.startPageQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onExitCommand {
                    if app.startPageQuery.isEmpty { searchFocused = false }
                    else { app.startPageQuery = "" }
                }
            if !app.startPageQuery.isEmpty {
                Button { app.startPageQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(L("清空搜索"))
            }
            Button { app.showQuickOpen() } label: {
                Text("⌘ K")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Theme.tabRailBackground, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.separator, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help(L("快速打开"))
        }
        .padding(.horizontal, 7)
        .frame(width: 270, height: 33)
        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(searchFocused ? Theme.accent.opacity(0.65) : Theme.separator, lineWidth: 1))
    }

    private var actionsMenu: some View {
        Menu {
            Button(L("新建主机")) { app.editingHost = SSHHost(name: L("新主机")) }
            Button(L("新建 SFTP 标签…")) { app.beginNewSFTPTab() }
                .disabled(app.hosts.isEmpty)
            Button(L("新建分组…")) { app.beginNewGroup() }
            Button(L("新建工作区…")) { app.promptCreateBoard() }
            Divider()
            Button(L("从 ~/.ssh/config 导入")) { app.importSSHConfig() }
            Button(L("从 Termius 导入…")) { app.beginTermiusImport() }
            Divider()
            Button(L("快速打开…")) { app.showQuickOpen() }
            Button(L("传输中心")) { app.showingTransferCenter = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("更多操作"))
    }

    private func chromeButton(_ glyph: String, title: String, label: String? = nil,
                              selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph).font(.system(size: 12, weight: .medium))
                if let label { Text(label).font(.system(size: 12)) }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(selected ? Theme.rowSelection : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .help(title)
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
    case boardCreate
    case board(BoardDefinition)
    case boardName
    case newSFTPTab
    case termiusImport
    case password(PasswordPrompt)
    case hostKey(HostKeyPrompt)
    case conflict(PendingConflict)
    case commandConfirmation(CommandConfirmationPrompt)
    case editor(EditorContext)

    var id: String {
        switch self {
        case .host(let host): return "host-" + host.id.uuidString
        case .group(let group): return "group-" + group.id.uuidString
        case .proxy(let proxy): return "proxy-" + proxy.id.uuidString
        case .keyImporter: return "keyImporter"
        case .settings: return "settings"
        case .transfers: return "transfers"
        case .boardCreate: return "boardCreate"
        case .board(let board): return "board-" + board.id.uuidString
        case .boardName: return "boardName"
        case .newSFTPTab: return "newSFTPTab"
        case .termiusImport: return "termiusImport"
        case .password(let prompt): return "password-" + prompt.id.uuidString
        case .hostKey(let prompt): return "hostKey-" + prompt.id.uuidString
        case .conflict(let conflict): return "conflict-" + conflict.id.uuidString
        case .commandConfirmation(let prompt): return "commandConfirmation-" + prompt.id.uuidString
        case .editor(let context): return "editor-" + context.id.uuidString
        }
    }
}

/// White working surfaces with silver chrome, with matching dark appearances
/// for the rest of the app. Terminal themes remain independent of this palette.
enum Theme {
    /// Canvas behind the workspace and the chrome around terminal panes.
    static let windowBackground = Color(nsColor: windowBackgroundNSColor)
    /// The same canvas as an `NSColor`; AppKit views that paint themselves
    /// (split gutters) used `NSColor.windowBackgroundColor` and left a pure
    /// white / #1E1E1E seam against the tinted canvas.
    static let windowBackgroundNSColor = dynamicNSColor(light: 0xFFFFFF, dark: 0x1B1D20)
    static let titleBarGradient = LinearGradient(
        colors: [dynamic(light: 0xFFFFFF, dark: 0x24262A),
                 dynamic(light: 0xF7F8FA, dark: 0x272A2E),
                 dynamic(light: 0xE9EDF3, dark: 0x2C3035)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let tabRailBackground = dynamic(light: 0xF2F5F8, dark: 0x222529)
    /// Host sidebar, settings sidebar, workspace pane list.
    static let sidebarBackground = dynamic(light: 0xFFFFFF, dark: 0x202327)
    /// Cards, sheets and list panels that sit on top of the window.
    static let panelBackground = dynamic(light: 0xFAFBFC, dark: 0x24272B)
    /// Toolbar and tab strip bands.
    static let headerBackground = dynamic(light: 0xF6F8FA, dark: 0x24272C)
    /// The title bar of a terminal pane, painted opaquely over the terminal so it
    /// never depends on what the shell is drawing underneath.
    static let paneHeader = dynamic(light: 0xF5F7FA, dark: 0x292C31)
    /// Text fields, search shells and the path bar.
    static let fieldBackground = dynamic(light: 0xFFFFFF, dark: 0x2A2D32)
    /// Raised cards (start page tiles, settings cards).
    static let cardBackground = dynamic(light: 0xFFFFFF, dark: 0x24272B)
    static let cardStroke = dynamic(light: 0xDCE1E8, dark: 0x343940)
    /// Hairlines, header bars and the path field shell.
    static let separator = dynamic(light: 0xE4E8EE, dark: 0x34383E)
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
    static let rowSelection = dynamic(light: 0xEFF2F6, dark: 0x30353B)

    /// A low-chroma rendering of an identity color for repeated chrome such
    /// as host badges. The saved color and status colors are separate.
    static func quietIdentity(_ color: Color) -> Color {
        let source = NSColor(color)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let neutral = NSColor(themeHex: isDark ? 0xA5AFBA : 0x5C6775)
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = source.usingColorSpace(.sRGB)
            }
            guard let resolved else { return neutral }
            return neutral.blended(withFraction: isDark ? 0.15 : 0.30, of: resolved) ?? neutral
        })
    }

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
