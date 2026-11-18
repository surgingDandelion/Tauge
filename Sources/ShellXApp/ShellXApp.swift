import SwiftUI
import ShellXKit
import AppKit

@main
enum TaugeMain {
    static func main() {
        // Diagnostic used by the packaging scripts and by anyone checking an
        // installed build: load the localisation table without starting AppKit and
        // fail loudly if the resource bundle cannot be read. This is the check
        // that would have caught the 1.0.0 bundle-layout crash before shipping.
        if CommandLine.arguments.contains("--verify-localization") {
            let count = TaugeL10n.shared.englishTranslations.count
            FileHandle.standardError.write(Data("localization entries: \(count)\n".utf8))
            exit(count > 700 ? 0 : 1)
        }
        // Scriptable update probe: asks GitHub for the latest release without
        // starting AppKit. Used by packaging checks and by anyone verifying
        // that a build can reach the update feed.
        if CommandLine.arguments.contains("--check-updates") {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var status: Int32 = 0
            Task.detached {
                do {
                    let result = try await TaugeUpdateService.shared.checkForUpdate(currentVersion: TaugeAppInfo.version)
                    switch result {
                    case .upToDate(let current):
                        print("up to date: \(current)")
                    case .available(let update):
                        print("update available: \(update.version) (current \(TaugeAppInfo.version))")
                        print("archive: \(update.archiveURL.absoluteString)")
                    }
                } catch {
                    FileHandle.standardError.write(Data("update check failed: \(error.localizedDescription)\n".utf8))
                    status = 1
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(status)
        }
        ShellXApp.main()
    }
}

struct ShellXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup("Tauge") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands { ShellXCommands(app: app) }

        Settings {
            SettingsView()
                .environmentObject(app)
                .frame(width: 640, height: 520)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var statusItem: NSStatusItem?
    private var windowObservers: [NSObjectProtocol] = []
    private var languageObserver: NSObjectProtocol?
    /// The window that hosts `ContentView`. Only this one closing means "quit":
    /// SwiftUI also owns hidden host windows that come and go on their own.
    private weak var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One process per app: clicking the Dock icon while a copy is already
        // running has to raise that window, not start a second process that
        // leaves a second menu-bar icon behind. (SHELLX_SINGLE_INSTANCE=0 is the
        // escape hatch used by the test harness to run a scratch instance next
        // to the real app.)
        guard ProcessInfo.processInfo.environment["SHELLX_SINGLE_INSTANCE"] != "0" else { return }
        let identifier = Bundle.main.bundleIdentifier ?? ""
        guard !identifier.isEmpty else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launching from Finder or a terminal should bring the window up like
        // any other app instead of staying behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.styleMask.contains(.titled) }) else { return }
            self?.mainWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        installStatusItem()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .taugeLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.installStatusItem()
        }
        observeWindowClosing()
        WindowSnapshot.runIfRequested()
        // Cmd+W belongs to tabs, not to the window. SwiftUI always installs a
        // Close Window item for WindowGroup, so we intercept the key down and
        // close the active tab when one is open.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let app = AppState.shared
            if flags == .command, event.charactersIgnoringModifiers == "w" {
                guard let tab = app.selectedTab else { return event }
                app.closeTab(tab)
                return nil
            }
            // Whatever AppKit made first responder (the SwiftUI host, a tab
            // chip, the sidebar) may be unable to route a keystroke to the
            // shell. Give the terminal the keyboard before dispatch so typing
            // never silently stops; text fields keep their own keys.
            app.handOffKeyEventToTerminalIfNeeded(event)
            return event
        }
        FocusSelfTest.runIfRequested()
        // GitHub-tag updater: check once shortly after launch, at most daily.
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Coming back from another app leaves the keyboard on the window itself.
        AppState.shared.restoreTerminalFocusIfNeeded()
        // Tabs and panes restored from the catalog are idle until something
        // dials them; coming back to the window is the natural moment.
        AppState.shared.resumeIdleSelection()
    }

    // MARK: - Menu bar item

    /// A template ("black and white") squircle in the menu bar, so it adapts to
    /// light, dark and tinted menu bars instead of looking like a coloured photo.
    private func installStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
            button.toolTip = L("Tauge — 本地 SSH / SFTP 客户端")
        }

        let menu = NSMenu()
        menu.addItem(statusItem(L("打开 Tauge 窗口"), #selector(openWindowFromMenuBar)))
        menu.addItem(.separator())
        menu.addItem(statusItem(L("新建 SFTP 标签…"), #selector(newSFTPTabFromMenuBar)))
        menu.addItem(statusItem(L("新建终端标签"), #selector(newTerminalTabFromMenuBar)))
        menu.addItem(.separator())
        menu.addItem(statusItem(L("快速打开…"), #selector(commandPaletteFromMenuBar)))
        menu.addItem(statusItem(L("传输中心…"), #selector(transferCenterFromMenuBar)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 Tauge"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func statusItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.styleMask.contains(.titled) && $0.canBecomeMain }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openWindowFromMenuBar() {
        showMainWindow()
    }

    @objc private func newSFTPTabFromMenuBar() {
        showMainWindow()
        AppState.shared.beginNewSFTPTab()
    }

    @objc private func newTerminalTabFromMenuBar() {
        showMainWindow()
        AppState.shared.openTerminalTabFromSelection()
    }

    @objc private func commandPaletteFromMenuBar() {
        showMainWindow()
        AppState.shared.showQuickOpen()
    }

    @objc private func transferCenterFromMenuBar() {
        showMainWindow()
        AppState.shared.showingTransferCenter = true
    }

    /// Closing the main window quits Tauge.
    ///
    /// `applicationShouldTerminateAfterLastWindowClosed` is not enough: SwiftUI
    /// keeps an invisible host window (and, once the menu-bar item exists, the
    /// process itself) alive, so the app used to keep running with no window,
    /// leaving the menu-bar icon behind and swallowing later Dock clicks. Watch
    /// the real windows instead and quit once no visible main window is left.
    private func observeWindowClosing() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow,
                  closing.sheetParent == nil,
                  closing === self?.mainWindow else { return }
            Task { @MainActor in
                // Let SwiftUI finish its own teardown before deciding.
                try? await Task.sleep(nanoseconds: 200_000_000)
                let remaining = NSApp.windows.filter {
                    $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
                }
                if remaining.isEmpty { NSApp.terminate(nil) }
            }
        }
        windowObservers.append(observer)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon (or opening the .app again) must raise the
        // window instead of doing nothing.
        NSApp.activate(ignoringOtherApps: true)
        if !flag {
            sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        AppState.shared.saveCurrentBoardIfDirty()
        // Must be synchronous here: a debounced Task will not run before the
        // process exits.
        AppState.shared.flushWorkspace()
    }
}

/// The app icon's squircle with the script "T" knocked out, rendered at 18pt and
/// marked as a template image so macOS tints it for the current menu bar.
///
/// The PNGs are looked up without `Bundle.module`: that accessor traps (SIGTRAP in
/// `NSBundle.module`) when the SwiftPM resource bundle is not shipped inside the
/// `.app`, which is exactly how `scripts/build-app.sh` packages it — it copies the
/// files into `Contents/Resources/Assets` instead.
enum MenuBarIcon {
    static func image() -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        var reps: [NSBitmapImageRep] = []

        for name in ["MenuIcon", "MenuIcon@2x", "MenuIcon@3x"] {
            guard let url = pngURL(named: name),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize
            reps.append(rep)
        }

        guard !reps.isEmpty else {
            let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Tauge")
                ?? NSImage(size: pointSize)
            symbol.isTemplate = true
            return symbol
        }

        let image = NSImage(size: pointSize)
        for rep in reps { image.addRepresentation(rep) }
        image.isTemplate = true
        return image
    }

    /// Search order covers both layouts: a packaged `.app` (Assets copied next to
    /// Info.plist) and `swift run`/`.build/debug/ShellX` (SwiftPM resource bundle
    /// sitting beside the executable).
    private static func pngURL(named name: String) -> URL? {
        let main = Bundle.main
        var directories: [URL] = []
        if let resources = main.resourceURL {
            directories.append(resources.appendingPathComponent("Assets"))
            directories.append(resources)
        }
        let executableDirectory = main.bundleURL
        directories.append(executableDirectory
            .appendingPathComponent("ShellX_ShellXApp.bundle/Contents/Resources/Assets"))
        directories.append(executableDirectory.appendingPathComponent("Assets"))

        let fileManager = FileManager.default
        for directory in directories {
            let candidate = directory.appendingPathComponent(name + ".png")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

struct ShellXCommands: Commands {
    @ObservedObject var app: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("检查更新…")) { UpdateController.shared.checkForUpdates(manual: true) }
        }

        CommandGroup(replacing: .newItem) {
            Button(L("新建主机")) { app.editingHost = SSHHost(name: L("新主机")) }
                .keyboardShortcut("n", modifiers: .command)
            Button(L("复制主机…")) {
                if let host = app.selectedSidebarHost ?? app.selectedTab?.host {
                    app.duplicateHost(host)
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(app.selectedSidebarHost == nil && app.selectedTab == nil)
            Button(L("新建分组")) { app.beginNewGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(L("从 ~/.ssh/config 导入")) { app.importSSHConfig() }
            Button(L("从 Termius 导入…")) { app.beginTermiusImport() }
        }

        CommandGroup(replacing: .saveItem) {
            // A workspace assembled from dragged tabs has no name yet: saving
            // it asks for one first (see AppState.requestSaveCurrentBoard).
            Button(L("保存工作区")) { app.requestSaveCurrentBoard() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.currentBoard == nil || !app.boardDirty)
        }

        CommandMenu(L("标签")) {
            Button(L("新建标签")) { newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(app.hosts.isEmpty)
            Button(L("新建 SFTP 标签…")) { app.beginNewSFTPTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(app.hosts.isEmpty)
            Button(L("关闭标签")) {
                if let tab = app.selectedTab { app.closeTab(tab) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(app.selectedTab == nil)
            Divider()
            Button(L("重新连接")) {
                if let tab = app.selectedTab { app.reconnect(tab) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(app.selectedTab == nil)
            Button(L("显示/隐藏 SFTP")) {
                if let tab = app.selectedTab { app.toggleSFTP(tab) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(app.selectedTab == nil || app.selectedTab?.kind == .sftp)
            Divider()
            Button(L("回到起始页")) { app.showStartPage() }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(1...9, id: \.self) { index in
                Button(L("标签 ") + String(index)) {
                    app.selectTab(at: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
            }
        }

        CommandMenu(L("导航")) {
            Button(L("快速打开…")) { app.showQuickOpen() }
                .keyboardShortcut("k", modifiers: .command)
            Button(L("传输中心")) { app.showingTransferCenter = true }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button(L("起始页")) { app.showStartPage() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(L("新建工作区…")) { app.promptCreateBoard() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button(app.settings.broadcastInput ? L("关闭命令广播") : L("开启命令广播")) {
                app.toggleBroadcastingInput()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(!app.isWorkspaceSelected || app.boardSessions.isEmpty)
            Divider()
            Button(app.settings.sidebarVisible ? L("隐藏侧边栏") : L("显示侧边栏")) { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button(L("全部分组展开/折叠")) {
                app.searchText = ""
            }
        }
    }

    private func newTab() {
        if let hostID = app.selectedSidebarHostID, let host = app.host(id: hostID) {
            app.openTab(for: host)
            return
        }
        if let tab = app.selectedTab {
            app.openTab(for: tab.host, showsSFTP: tab.showsSFTP)
            return
        }
        if let first = app.hosts.first { app.openTab(for: first) }
    }
}
