import AppKit
import Foundation
import SwiftUI
import ShellXKit

/// A credential request raised while a connection is being established. The
/// connect task suspends until the UI sheet resumes it.
struct PasswordPrompt: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var isPassphrase: Bool
    var initialValue: String = ""
}

/// A host-key confirmation. "changed" prompts show both fingerprints and block
/// the connection until the user explicitly accepts the new key.
struct HostKeyPrompt: Identifiable {
    let id = UUID()
    var info: HostKeyInfo
    var previousFingerprint: String?
    var isChanged: Bool
}

struct PendingConflict: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var fileCount: Int
}

/// A tiny in-app text editor for remote files below the configured size limit.
struct EditorContext: Identifiable {
    let id = UUID()
    var tabID: UUID
    /// Which remote pane the file came from; nil means the tab's main pane.
    var paneID: UUID?
    var path: String
    var text: String
    var isDirty = false
}

struct CommandPaletteItem: Identifiable {
    enum Kind { case host, action, recent }
    let id: String
    var title: String
    var subtitle: String
    var kind: Kind
    var host: SSHHost?
    var action: (() -> Void)?
    /// Header row the item belongs to. The palette renders hosts under their
    /// group path, so opening a machine with ⌘K shows the same tree as the
    /// sidebar instead of one flat alphabetical list.
    var groupTitle: String?
    /// Nesting depth of the host's group, used to indent the row.
    var depth: Int = 0
    /// Extra strings the row answers to (address, group path, tags, pinyin…).
    var keywords: [String] = []
    /// Recency tie-breaker for the ranking; see `QuickOpen`.
    var weight: Int = 0
}

struct SidebarGroupNode: Identifiable {
    var group: HostGroup
    var children: [SidebarGroupNode]
    var hosts: [SSHHost]
    var id: UUID { group.id }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let environment: AppEnvironment
    let store: HostStore

    @Published private(set) var groups: [HostGroup] = []
    @Published private(set) var hosts: [SSHHost] = []
    @Published private(set) var proxies: [ProxyConfig] = []
    @Published private(set) var keys: [PrivateKeyRecord] = []
    @Published var knownHosts: [KnownHostEntry] = []
    @Published var recentHosts: [SSHHost] = []
    /// Operating system detected after login, per host. Drives the sidebar,
    /// start-page and SFTP headers, which swap the generic server glyph for the
    /// matching logo as soon as this dictionary gains the host.
    @Published private(set) var hostPlatforms: [UUID: HostPlatformInfo] = [:]

    @Published var settings: AppSettings
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    @Published var expandedGroups: Set<UUID> = []
    @Published var searchText = ""
    @Published var selectedSidebarHostID: UUID?
    /// Which collection the start page highlights (all / favorites / a group…).
    /// Session state, not a setting: it survives leaving the page for a tab but
    /// resets on the next launch, like the sidebar selection.
    @Published var startPageSelection: StartPageSelection = .all
    /// Group views include every descendant by default. The start page can
    /// still narrow the view to the selected group itself when needed.
    @Published var startPageShowsDescendants = true
    /// Workspace tabs. A workspace (formerly called "board") is a set of terminal
    /// panes laid out as nested splits; it lives in the same tab strip as single
    /// connections, so both are first-class tabs.
    @Published var openBoardIDs: [UUID] = []
    @Published var selectedBoardID: UUID?
    @Published internal(set) var boards: [BoardDefinition] = []
    @Published var currentBoard: BoardDefinition?
    /// Structural workspace edits (panes added or removed) are not written to
    /// the catalog immediately: the header shows 未保存 and ⌘S commits them.
    @Published var boardDirty = false
    @Published internal(set) var boardSessions: [TerminalTab] = []
    /// Sessions stay alive when the user switches to another board; this keeps
    /// their connections (and scrollback) around.
    var boardSessionCache: [UUID: [UUID: TerminalTab]] = [:]
    var boardSaveTask: Task<Void, Never>?
    /// Workspaces that exist only in memory: they were created by dragging one
    /// tab onto another, and only enter the catalog when the user saves them
    /// (⌘S asks for the name first). Closing the workspace or quitting drops
    /// them, which is what “没保存就不用管它” means in practice.
    var draftBoardIDs: Set<UUID> = []

    // Sheets and alerts.
    @Published var editingHost: SSHHost?
    @Published var editingGroup: HostGroup?
    @Published var editingBoard: BoardDefinition?
    @Published var editingProxy: ProxyConfig?
    @Published var showingKeyImporter = false
    @Published var showingSettings = false
    @Published var showingTransferCenter = false
    @Published var showingCommandPalette = false
    @Published var showingBoardCreate = false
    /// Set when saving a draft workspace: the sheet asks for the name it should
    /// keep in the catalog.
    @Published var boardNamePrompt: BoardNamePrompt?
    /// Host chooser for "新建 SFTP 标签" (one local pane, one remote pane each).
    @Published var showingNewSFTPTab = false
    @Published var showingImportSheet = false
    @Published var showingSSHConfigImport = false
    /// Preview session for the Termius importer (nil when the sheet is closed).
    @Published var termiusImport: TermiusImportSession?
    @Published var alert: AppError?
    /// True when the catalog opened but refuses writes (read-only file, folder or sandbox).
    @Published private(set) var catalogReadOnly: Bool = false

    // Async prompts.
    @Published var passwordPrompt: PasswordPrompt?
    @Published var hostKeyPrompt: HostKeyPrompt?
    @Published var pendingConflict: PendingConflict?
    @Published var editor: EditorContext?

    @Published private(set) var transfers: [TransferProgress] = []
    @Published var transferConflictPolicy: ConflictPolicy?

    var passwordContinuation: CheckedContinuation<String?, Never>?
    var hostKeyContinuation: CheckedContinuation<HostKeyDecision, Never>?
    var conflictContinuation: CheckedContinuation<ConflictPolicy?, Never>?
    /// Conflict dialogs are global to the app window. Keep later drops queued
    /// instead of replacing the continuation that the first transfer awaits.
    var conflictWaiters: [CheckedContinuation<Void, Never>] = []
    private var workspaceSaveTask: Task<Void, Never>?

    private init() {
        let environment = AppEnvironment.make()
        self.environment = environment
        self.catalogReadOnly = environment.isReadOnlyCatalog
        store = environment.store
        settings = (try? environment.store.settings()) ?? AppSettings()
        TaugeL10n.shared.language = TaugeLanguage(rawValue: settings.language) ?? .systemDefault
        reloadCatalog()
        expandedGroups = Set(groups.filter { $0.isExpanded }.map { $0.id })
        loadTransferHistory()
        subscribeToTransfers()
        restoreWorkspace()
        restoreBoards()
        connectInitialWorkspace()
        applyAppearance()
        if catalogReadOnly {
            presentCatalogReadOnlyNotice()
        } else if environment.isEphemeralDatabase {
            let reason = environment.catalogOpenFailure.map { L("\n原因：") + $0 } ?? ""
            presentMessage(L("正在使用临时数据库"),
                           L("无法打开原数据库：\n") + CatalogLocation.currentURL.path + reason
                               + L("\n\n本次运行使用的是临时数据库，退出后数据会丢失。"),
                           suggestion: L("请检查该文件是否被占用或损坏；也可以在“设置 → 高级”中迁移数据库到可写位置。"))
        }
    }

    /// The catalog is opened but not writable, which would otherwise surface as a raw
    /// "attempt to write a readonly database" SQL error on the first save.
    func presentCatalogReadOnlyNotice() {
        var detail = L("Tauge 已打开数据库：\n") + environment.databaseURL.path
        if let reason = environment.catalogOpenFailure {
            detail += L("\n\n无法以可写方式打开：") + reason
            detail += L("\n\n已按只读方式加载，主机与分组仍可查看和使用，但任何修改都不会被保存。")
        } else {
            detail += L("\n\n当前进程没有写入权限，新建主机、修改分组或保存设置都不会被保存。")
        }
        presentMessage(L("数据库不可写（只读）"), detail,
                       suggestion: L("请从 Finder 直接启动 Tauge.app（不要在受限沙盒或只读环境中运行）；也可以在“设置 → 高级”中把数据库迁移到可写位置。"))
    }

    var catalogPath: String { environment.databaseURL.path }

    /// Copies the catalog into a writable folder chosen by the user and remembers the
    /// location for the next launch.
    func chooseCatalogLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("迁移到这里")
        panel.message = L("选择一个可写文件夹，Tauge 会复制当前数据库，并在下次启动时使用新位置。")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let target = try environment.relocateCatalog(to: directory)
            catalogReadOnly = false
            presentMessage(L("数据库已迁移"),
                           L("数据库已复制到：\n") + target.path,
                           suggestion: L("请退出 Tauge 并重新启动，之后的所有修改都会保存到新位置。"))
        } catch {
            present(error, title: L("迁移数据库失败"))
        }
    }

    func revealCatalogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([environment.databaseURL])
    }

    // MARK: - Catalog

    func reloadCatalog() {
        do {
            groups = try store.groups().sorted { $0.sortIndex < $1.sortIndex }
            hosts = try store.hosts().sorted {
                $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
            }
            proxies = try store.proxies()
            keys = try store.privateKeys()
            knownHosts = try store.hostKeys()
            recentHosts = try store.recentHosts(limit: 20)
            hostPlatforms = try store.hostPlatforms()
        } catch {
            present(error)
        }
    }

    var favoriteHosts: [SSHHost] {
        hosts.filter { $0.tags.contains { $0.lowercased() == "favorite" || $0 == "收藏" } }
    }

    func host(id: UUID?) -> SSHHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    /// The host the sidebar currently highlights. Menu commands that act on
    /// "the selected host" (duplicate, delete, edit) read this instead of
    /// digging into the selection state themselves.
    var selectedSidebarHost: SSHHost? {
        host(id: selectedSidebarHostID)
    }

    // MARK: - Detected platform

    func platform(for hostID: UUID?) -> HostPlatform? {
        guard let hostID else { return nil }
        return hostPlatforms[hostID]?.platform
    }

    func platformInfo(for hostID: UUID?) -> HostPlatformInfo? {
        guard let hostID else { return nil }
        return hostPlatforms[hostID]
    }

    /// Probes the host over the connection that just came up. The result is cached
    /// in the database, so reconnects and extra SFTP panes cost no round trip; a
    /// host whose platform was already detected keeps its logo even while offline.
    func detectPlatformIfNeeded(hostID: UUID, client: SSHClient) {
        guard hostPlatforms[hostID] == nil else { return }
        Task { [weak self] in
            guard let info = await HostPlatformDetector.detect(using: client) else { return }
            self?.applyPlatform(info, hostID: hostID)
        }
    }

    /// Drops the cached detection and probes again; used by the sidebar menu when a
    /// host was reinstalled with a different OS.
    func redetectPlatform(hostID: UUID) {
        hostPlatforms[hostID] = nil
        try? store.clearHostPlatform(for: hostID)
        if let client = tabs.first(where: { $0.hostID == hostID })?.client {
            detectPlatformIfNeeded(hostID: hostID, client: client)
        }
    }

    private func applyPlatform(_ info: HostPlatformInfo, hostID: UUID) {
        hostPlatforms[hostID] = info
        try? store.setHostPlatform(info, for: hostID)
    }

    func group(id: UUID?) -> HostGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func hostName(for id: UUID?) -> String {
        host(id: id).map(TerminalTab.label(for:)) ?? L("未知主机")
    }

    func proxyName(for policy: ProxyPolicy) -> String {
        switch policy {
        case .direct: return L("不使用代理")
        case .inherit: return L("继承分组设置")
        case .use(let id): return proxies.first { $0.id == id }?.name ?? L("已删除的代理")
        }
    }

    func jumpDescription(for policy: JumpPolicy) -> String {
        switch policy {
        case .direct: return L("直连")
        case .inherit: return L("继承分组设置")
        case .hosts(let ids):
            if ids.isEmpty { return L("直连") }
            return ids.compactMap { host(id: $0)?.name }.joined(separator: " → ")
        }
    }

    /// Groups tree for the sidebar, honoring the search filter.
    var sidebarTree: [SidebarGroupNode] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty ? hosts : hosts.filter { matchesSearch($0, query: query) }
        return buildTree(parentID: nil, hosts: matches)
    }

    var ungroupedHosts: [SSHHost] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let list = hosts.filter { $0.groupID == nil }
        guard !query.isEmpty else { return list }
        return list.filter { matchesSearch($0, query: query) }
    }

    private func buildTree(parentID: UUID?, hosts source: [SSHHost]) -> [SidebarGroupNode] {
        groups.filter { $0.parentID == parentID }
            .sorted { $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex }
            .compactMap { group -> SidebarGroupNode? in
                let children = buildTree(parentID: group.id, hosts: source)
                let owned = source.filter { $0.groupID == group.id }.sorted { $0.sortIndex < $1.sortIndex }
                if !searchText.isEmpty && owned.isEmpty && children.isEmpty { return nil }
                return SidebarGroupNode(group: group, children: children, hosts: owned)
            }
    }

    func matchesSearch(_ host: SSHHost, query: String) -> Bool {
        let needle = query.lowercased()
        let fields = [host.name, host.hostname, host.username, host.notes] + host.tags
        for field in fields where field.lowercased().contains(needle) {
            return true
        }
        // Pinyin initials: "cs" matches "测试服务器".
        let initials = Self.pinyinInitials(host.name)
        if !initials.isEmpty && initials.contains(needle) { return true }
        let latin = Self.latinized(host.name)
        return latin.contains(needle)
    }

    static func latinized(_ value: String) -> String {
        guard let transformed = value.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) else { return value.lowercased() }
        return transformed.lowercased()
    }

    // MARK: - Groups

    /// Full "A / B / C" path for a group, used in pickers and board titles.
    func groupPath(for id: UUID?) -> String {
        guard let id else { return L("未分组") }
        var components: [String] = []
        var current = group(id: id)
        var guardCounter = 0
        while let node = current, guardCounter < 32 {
            components.insert(node.name, at: 0)
            current = node.parentID.flatMap { group(id: $0) }
            guardCounter += 1
        }
        return components.isEmpty ? L("未分组") : components.joined(separator: " / ")
    }

    /// Every host directly inside a group, optionally including descendant groups.
    func hosts(inGroup groupID: UUID, includingDescendants: Bool = true) -> [SSHHost] {
        var ids: Set<UUID> = [groupID]
        if includingDescendants {
            var changed = true
            while changed {
                changed = false
                for group in groups {
                    guard let parent = group.parentID, ids.contains(parent), !ids.contains(group.id) else { continue }
                    ids.insert(group.id)
                    changed = true
                }
            }
        }
        return hosts.filter { $0.groupID.map { ids.contains($0) } ?? false }
    }

    /// True when the tab strip's selected item is a workspace tab.
    var isWorkspaceSelected: Bool {
        guard let selectedBoardID else { return false }
        return currentBoard?.id == selectedBoardID
    }

    /// True when the start page (every host, every workspace) is the visible
    /// tab. The start page is a permanent chip on the left of the strip, so the
    /// strip needs a selection state for it just like real tabs.
    var isStartPageSelected: Bool {
        selectedTabID == nil && !isWorkspaceSelected
    }

    var openBoards: [BoardDefinition] {
        openBoardIDs.compactMap { id in boards.first { $0.id == id } }
    }

    /// Dials whatever ended up selected after restoring the workspace; tabs that
    /// belong to an unselected workspace stay dormant.
    func connectInitialWorkspace() {
        // Restored tabs carry the strip layout only, so every one of them comes
        // back idle. Dial them all: a tab the user left open should be live
        // again after a restart, whether or not a workspace happens to be the
        // selected tab at launch.
        for tab in tabs where tab.connectionState == .idle {
            connect(tab: tab)
        }
        if isWorkspaceSelected {
            connectAllBoardSessions()
        }
    }

    /// Dials whatever the strip is showing when Tauge comes back to the front.
    ///
    /// Restored tabs and workspace panes are idle until something connects them.
    /// Launch handles the normal case, but a window restored behind another app,
    /// or a workspace that was not the selected tab at launch, only gets its
    /// turn when the user activates the app.
    func resumeIdleSelection() {
        if isWorkspaceSelected {
            for session in boardSessions where session.connectionState == .idle {
                connectBoardSession(session)
            }
        } else if let tab = selectedTab {
            connectIfIdle(tab)
        }
    }

    // MARK: - SFTP folder history

    func lastSFTPPath(for hostID: UUID?) -> String? {
        guard let hostID else { return nil }
        return (try? store.lastSFTPPath(hostID: hostID)) ?? nil
    }

    func sftpHistory(for hostID: UUID?, limit: Int = 10) -> [SFTPHistoryEntry] {
        guard let hostID else { return [] }
        return (try? store.sftpHistory(hostID: hostID, limit: limit)) ?? []
    }

    func recordSFTPPath(_ path: String, for hostID: UUID?) {
        guard let hostID, !path.isEmpty else { return }
        try? store.recordSFTPPath(hostID: hostID, path: path)
    }

    func clearSFTPHistory(for hostID: UUID?) {
        guard let hostID else { return }
        try? store.clearSFTPHistory(hostID: hostID)
    }

    /// Remembers the local pane folder without republishing every settings key.
    func recordLocalDirectory(_ path: String) {
        guard !path.isEmpty, settings.lastLocalDirectory != path else { return }
        settings.lastLocalDirectory = path
        try? store.save(settings: settings)
    }

    /// Wires a remote pane so every folder it visits is remembered per host.
    func configureSFTPHistory(for pane: RemoteBrowserModel) {
        pane.onDirectoryChange = { [weak self, weak pane] path in
            guard let self, let pane else { return }
            self.recordSFTPPath(path, for: pane.hostID)
        }
    }

    static func pinyinInitials(_ value: String) -> String {
        let latin = latinized(value)
        let syllables = latin.split(whereSeparator: { $0 == " " || $0 == "-" })
        var result = ""
        for syllable in syllables {
            if let first = syllable.first, first.isLetter { result.append(first) }
        }
        return result.isEmpty ? latin : result
    }

    // MARK: - Hosts and groups

    func saveHost(_ host: SSHHost) {
        var updated = host
        updated.updatedAt = Date()
        if updated.name.trimmingCharacters(in: .whitespaces).isEmpty {
            updated.name = updated.hostname
        }
        do {
            try store.save(host: updated)
            reloadCatalog()
            syncOpenTabs()
            editingHost = nil
        } catch {
            present(error)
        }
    }

    func deleteHost(_ id: UUID) {
        for tab in tabs where tab.hostID == id { closeTab(tab) }
        do {
            try store.deleteHost(id: id)
            reloadCatalog()
        } catch {
            present(error)
        }
    }

    /// Creates a copy of `host` and immediately opens it in the editor so the
    /// new name can be adjusted before it is saved. Saved passwords and key
    /// passphrases follow the copy, otherwise the duplicate would look complete
    /// in the list but fail to authenticate.
    func duplicateHost(_ host: SSHHost) {
        var copy = host
        copy.id = UUID()
        copy.name = duplicateName(basedOn: host.name)
        copy.createdAt = Date()
        copy.lastUsedAt = nil
        copy.useCount = 0
        copySecrets(from: host.id, to: copy.id)
        editingHost = copy
    }

    /// "name 副本", then "name 副本 2", "name 副本 3"… so repeated copies of the
    /// same host stay distinguishable in the sidebar and the start page.
    private func duplicateName(basedOn name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? L("主机") : name
        let taken = Set(hosts.map { $0.name })
        let first = base + L(" 副本")
        if !taken.contains(first) { return first }
        var index = 2
        while taken.contains(first + " " + String(index)) { index += 1 }
        return first + " " + String(index)
    }

    private func copySecrets(from source: UUID, to target: UUID) {
        for (from, to) in [(SecretAccount.hostPassword(source), SecretAccount.hostPassword(target)),
                           (SecretAccount.hostPassphrase(source), SecretAccount.hostPassphrase(target))] {
            guard let stored = try? environment.secrets.secret(for: from), !stored.isEmpty else { continue }
            try? environment.secrets.setSecret(stored, for: to)
        }
    }

    func toggleFavorite(_ host: SSHHost) {
        var updated = host
        if let index = updated.tags.firstIndex(where: { $0.lowercased() == "favorite" || $0 == "收藏" }) {
            updated.tags.remove(at: index)
        } else {
            updated.tags.append("favorite")
        }
        do {
            try store.save(host: updated)
            reloadCatalog()
            syncOpenTabs()
        } catch {
            present(error)
        }
    }

    /// Opens the group editor for a brand new group. Every entry point routes
    /// through here so a new child group is nested under its parent and the
    /// parent is expanded, otherwise the sheet would just create a sibling.
    func beginNewGroup(parentID: UUID? = nil) {
        editingGroup = HostGroup(parentID: parentID, name: L("新分组"))
        if let parentID, let parent = group(id: parentID) {
            setGroupExpanded(parent, expanded: true)
        }
    }

    func saveGroup(_ group: HostGroup) {
        do {
            try store.save(group: group)
            reloadCatalog()
            editingGroup = nil
        } catch {
            present(error)
        }
    }

    func deleteGroup(_ id: UUID) {
        do {
            _ = try store.deleteGroup(id: id)
            reloadCatalog()
        } catch {
            present(error)
        }
    }

    func toggleGroupExpanded(_ group: HostGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
        var updated = group
        updated.isExpanded = expandedGroups.contains(group.id)
        try? store.setGroupExpanded(id: group.id, expanded: updated.isExpanded)
    }

    func setGroupExpanded(_ group: HostGroup, expanded: Bool) {
        if expanded {
            expandedGroups.insert(group.id)
        } else {
            expandedGroups.remove(group.id)
        }
        try? store.setGroupExpanded(id: group.id, expanded: expanded)
    }

    /// Moves a host into a group (or to the top level) from a sidebar drag.
    func moveHost(_ host: SSHHost, toGroup groupID: UUID?) {
        var updated = host
        updated.groupID = groupID
        do {
            try store.save(host: updated)
            reloadCatalog()
            syncOpenTabs()
        } catch {
            present(error)
        }
    }

    /// Drops one host onto another (or onto a group, when `targetID` is nil)
    /// and renumbers the destination group so the order survives a relaunch.
    ///
    /// Dropping downward inserts *after* the hovered host, dropping upward
    /// inserts before it — the usual file-manager feel. Cross-group drops land
    /// next to the target, and a nil target appends to the end of `groupID`.
    func moveHost(_ hostID: UUID, onto targetID: UUID?, in groupID: UUID?) {
        guard let dragged = host(id: hostID), dragged.id != targetID else { return }
        // Work in display order so the insert lands where the user pointed.
        let ordered = hosts.filter { $0.groupID == groupID }
        var members = ordered.filter { $0.id != hostID }
        if let targetID, let origin = members.firstIndex(where: { $0.id == targetID }) {
            let draggedIndex = ordered.firstIndex { $0.id == hostID }
            let targetIndex = ordered.firstIndex { $0.id == targetID }
            let movingDown = (draggedIndex ?? 0) < (targetIndex ?? 0)
            members.insert(dragged, at: movingDown ? min(origin + 1, members.count) : origin)
        } else {
            members.append(dragged)
        }
        do {
            for (position, member) in members.enumerated() {
                var updated = member
                updated.groupID = groupID
                updated.sortIndex = position
                if member.sortIndex != position || member.groupID != groupID || member.id == hostID {
                    try store.save(host: updated)
                }
            }
            reloadCatalog()
            syncOpenTabs()
        } catch {
            present(error)
        }
    }

    func syncOpenTabs() {
        for tab in tabs {
            if let host = host(id: tab.hostID) {
                tab.host = host
                tab.title = TerminalTab.label(for: host)
            }
        }
    }

    // MARK: - Proxies and keys

    func saveProxy(_ proxy: ProxyConfig) {
        do {
            try store.save(proxy: proxy)
            reloadCatalog()
            editingProxy = nil
        } catch {
            present(error)
        }
    }

    func deleteProxy(_ id: UUID) {
        do {
            try store.deleteProxy(id: id)
            reloadCatalog()
        } catch {
            present(error)
        }
    }

    func savePrivateKey(_ key: PrivateKeyRecord) {
        do {
            try store.save(privateKey: key)
            reloadCatalog()
        } catch {
            present(error)
        }
    }

    func deletePrivateKey(_ id: UUID) {
        try? environment.secrets.setSecret(nil, for: SecretAccount.privateKey(id))
        do {
            try store.deletePrivateKey(id: id)
            reloadCatalog()
        } catch {
            present(error)
        }
    }

    // MARK: - Keyboard focus

    /// The terminal that should own the keyboard right now: the focused pane of
    /// the workspace tab, otherwise the selected tab. Browser-only tabs have no
    /// terminal and therefore nothing to focus.
    var activeTerminalView: ShellXTerminalView? {
        (selectedBoardID != nil ? focusedBoardSession : selectedTab)?.bridge.view
    }

    /// True while one of our own sheets owns the window. The quick-open panel is
    /// an overlay, so raising it behind a sheet would be invisible: ⌘K waits.
    var hasPresentedSheet: Bool {
        passwordPrompt != nil || hostKeyPrompt != nil || pendingConflict != nil
            || editor != nil || editingHost != nil || editingGroup != nil || editingBoard != nil || editingProxy != nil
            || showingKeyImporter || showingSettings || showingTransferCenter
            || showingBoardCreate || boardNamePrompt != nil || showingNewSFTPTab
    }

    /// ⌘K. Opens the quick-open panel, or closes it when it is already up.
    func showQuickOpen() {
        guard !hasPresentedSheet else { return }
        showingCommandPalette.toggle()
        if showingCommandPalette {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// True while one of our own dialogs/sheets owns the keyboard.
    private var hasPresentedDialog: Bool {
        passwordPrompt != nil || hostKeyPrompt != nil || pendingConflict != nil
            || editor != nil || editingHost != nil || editingGroup != nil || editingBoard != nil || editingProxy != nil
            || showingKeyImporter || showingSettings || showingTransferCenter
            || showingCommandPalette || showingBoardCreate || boardNamePrompt != nil
    }

    /// Hands the keyboard back to the terminal. SwiftTerm's view never becomes
    /// first responder unless asked, so every piece of chrome that moves focus
    /// away (tab strip, find bar, sidebar, closing a dialog) has to call this,
    /// otherwise typing silently stops working until the app is relaunched.
    /// - Returns: true when the terminal now owns the keyboard, so the retry
    ///   loop below can stop early.
    @discardableResult
    func focusTerminal() -> Bool {
        guard !hasPresentedDialog, let terminal = activeTerminalView else { return false }
        let window = NSApp.keyWindow ?? terminal.window
        guard let window, window.attachedSheet == nil else {
            traceFocus("focusTerminal deferred: hasWindow=\(NSApp.keyWindow != nil || terminal.window != nil) active=\(NSApp.isActive)")
            return false
        }
        terminal.takeFocus()
        let focused = window.firstResponder === terminal
        traceFocus("focusTerminal -> " + responderDescription(window) + " focused=\(focused) key=\(window.isKeyWindow)")
        return focused
    }

    private static let focusTraceEnabled = ProcessInfo.processInfo.environment["SHELLX_TRACE_FOCUS"] == "1"

    private func traceFocus(_ message: @autoclosure () -> String) {
        guard AppState.focusTraceEnabled else { return }
        FileHandle.standardError.write(Data(("[focus] " + message() + "\n").utf8))
    }

    private func responderDescription(_ window: NSWindow?) -> String {
        guard let window else { return "no window" }
        guard let responder = window.firstResponder else { return "no responder" }
        return String(describing: type(of: responder))
    }

    /// Focus can only be handed over once the terminal view is in a key window,
    /// which happens a moment after connect (or after a restore). Retry a few
    /// times instead of giving up on the first attempt.
    func scheduleTerminalFocus(_ delay: TimeInterval = 0.08) {
        Task { @MainActor [weak self] in
            var wait = max(delay, 0.05)
            for _ in 0 ..< 6 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { return }
                if self.focusTerminal() { return }
                wait = min(wait * 2, 0.6)
            }
        }
    }

    /// Called from the window's key monitor before AppKit dispatches a key: if
    /// the first responder is SwiftUI chrome (the hosting view, a button, the
    /// tab strip …) the keystroke would be swallowed, so the terminal takes it.
    /// Text editing surfaces (search fields, path fields, the editor, the
    /// command palette) keep their keys.
    @discardableResult
    func handOffKeyEventToTerminalIfNeeded(_ event: NSEvent) -> Bool {
        guard !hasPresentedDialog,
              let window = event.window ?? NSApp.keyWindow,
              window.attachedSheet == nil,
              let terminal = activeTerminalView,
              terminal.window === window,
              !event.modifierFlags.contains(.command) else { return false }
        guard let responder = window.firstResponder else { return false }
        if responder === terminal { return false }
        if responder is NSText { return false }
        if responder is NSButton { return false }
        traceFocus("key handoff from " + String(describing: type(of: responder)))
        window.makeFirstResponder(terminal)
        return true
    }

    /// Restores focus when the app or its window becomes active again and AppKit
    /// left the keyboard on the window/hosting view itself.
    func restoreTerminalFocusIfNeeded() {
        guard !hasPresentedDialog,
              let window = NSApp.keyWindow,
              window.attachedSheet == nil,
              let terminal = activeTerminalView,
              terminal.window === window else { return }
        let responder: NSResponder? = window.firstResponder
        if responder === terminal || responder is NSText { return }
        let name = responder.map { String(describing: type(of: $0)) } ?? ""
        guard responder === window || responder == nil || name.hasPrefix("NSHostingView") else { return }
        traceFocus("restoreTerminalFocusIfNeeded from " + name)
        window.makeFirstResponder(terminal)
    }

    // MARK: - Tabs

    func openTab(for host: SSHHost, showsSFTP: Bool = false) {
        // Only a shell tab can satisfy "reuse connection": an SFTP tab for the
        // same host has no terminal channel to hand over.
        if host.reuseConnection,
           let existing = tabs.first(where: {
               $0.kind == .terminal && $0.hostID == host.id && $0.connectionState.isConnected
           }) {
            selectedTabID = existing.id
            selectedBoardID = nil
            persistSelectedBoard()
            persistWorkspace()
            scheduleTerminalFocus()
            return
        }
        let tab = TerminalTab(host: host,
                              localFiles: environment.localFiles,
                              startRemoteDirectory: lastSFTPPath(for: host.id) ?? host.startDirectory,
                              localStartDirectory: settings.lastLocalDirectory,
                              showsSFTP: showsSFTP)
        tab.local.onDirectoryChange = { [weak self] path in self?.recordLocalDirectory(path) }
        configureSFTPHistory(for: tab.remote)
        tab.local.showHidden = settings.showHiddenFiles
        tab.remote.showHidden = settings.showHiddenFiles
        tabs.append(tab)
        selectedTabID = tab.id
        selectedSidebarHostID = host.id
        connect(tab: tab)
        persistWorkspace()
        scheduleTerminalFocus(0.2)
    }

    func openTabs(for hosts: [SSHHost]) {
        for host in hosts { openTab(for: host) }
    }

    /// Opens a browser-only tab: no shell, one local pane and one remote pane
    /// per host. Extra servers can be added from the pane header afterwards.
    func openSFTPTab(for host: SSHHost, extraHostIDs: [UUID] = []) {
        let tab = TerminalTab(kind: .sftp,
                              host: host,
                              localFiles: environment.localFiles,
                              startRemoteDirectory: lastSFTPPath(for: host.id) ?? host.startDirectory,
                              localStartDirectory: settings.lastLocalDirectory,
                              showsSFTP: true)
        tab.local.onDirectoryChange = { [weak self] path in self?.recordLocalDirectory(path) }
        configureSFTPHistory(for: tab.remote)
        tab.local.showHidden = settings.showHiddenFiles
        tab.remote.showHidden = settings.showHiddenFiles
        tab.pendingPaneHostIDs = extraHostIDs
        tabs.append(tab)
        selectedTabID = tab.id
        selectedBoardID = nil
        selectedSidebarHostID = host.id
        connect(tab: tab)
        persistWorkspace()
    }

    /// Opens an SFTP tab for the current sidebar selection, if any.
    func openSFTPTabForSelection() {
        guard let id = selectedSidebarHostID, let host = host(id: id) else {
            presentMessage(L("没有选中的主机"),
                           L("先在起始页或侧边栏里选一台主机，再新建 SFTP 标签。"),
                           suggestion: L("也可以在主机上右键选择“新建 SFTP 标签”。"))
            return
        }
        openSFTPTab(for: host)
    }

    /// Opens the host chooser for a new SFTP tab; used by the start page and
    /// the tab strip, where no host has to be selected beforehand.
    func beginNewSFTPTab() {
        showingNewSFTPTab = true
    }

    /// Opens a terminal tab when the menu bar item is used: the host selected in
    /// the sidebar, otherwise the most recently connected one.
    func openTerminalTabFromSelection() {
        if let hostID = selectedSidebarHostID, let host = host(id: hostID) {
            openTab(for: host)
            return
        }
        if let host = recentHosts.first {
            openTab(for: host)
        }
    }

    func closeTab(_ tab: TerminalTab) {
        tab.close()
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
        }
        if selectedTabID == tab.id {
            selectedTabID = tabs.last?.id
        }
        persistWorkspace()
        scheduleTerminalFocus(0.15)
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabID = tab.id
        selectedBoardID = nil
        persistSelectedBoard()
        persistWorkspace()
        // A tab restored from the workspace snapshot comes back idle: the strip
        // keeps the layout, not the sockets. Selecting it has to dial it, or the
        // pane stays blank with nothing to click.
        connectIfIdle(tab)
        scheduleTerminalFocus(0.05)
    }

    func selectTab(at index: Int) {
        // Shortcut positions follow the tab strip's natural order: ordinary
        // tabs first, then open workspace tabs. The old implementation only
        // indexed `tabs`, so a workspace chip could never be reached with
        // Cmd+1…Cmd+9.
        if tabs.indices.contains(index) {
            selectTab(tabs[index])
            return
        }
        let boardIndex = index - tabs.count
        guard openBoards.indices.contains(boardIndex) else { return }
        openBoardTab(openBoards[boardIndex].id)
    }

    /// Clears the tab/workspace selection so the start page shows: every host,
    /// every workspace. This is the only way back to the start page once tabs
    /// exist, so it is on ⌘⇧H.
    func showStartPage() {
        selectedTabID = nil
        selectedBoardID = nil
        persistSelectedBoard()
        persistWorkspace()
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.id == selectedTabID }
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(to, tabs.count))
        persistWorkspace()
    }

    func reconnect(_ tab: TerminalTab) {
        tab.reconnectAttempt = 0
        connect(tab: tab)
    }

    // MARK: - Settings

    func updateSettings(_ newValue: AppSettings) {
        let languageChanged = newValue.language != settings.language
        settings = newValue
        if languageChanged {
            TaugeL10n.shared.language = TaugeLanguage(rawValue: newValue.language) ?? .systemDefault
        }
        do {
            try store.save(settings: newValue)
        } catch {
            present(error)
        }
        Task {
            await environment.transferEngine.updateConfiguration(.init(maxConcurrent: newValue.defaultTransferConcurrency,
                                                                       maxRetries: newValue.transferRetryCount))
        }
        applyAppearance()
    }

    /// Remembers when the updater last reached GitHub. The timestamp is what
    /// throttles the launch check to once a day; a manual check also refreshes
    /// it, so opening the update window always counts as a check.
    func recordUpdateCheck(_ date: Date = Date()) {
        settings.lastUpdateCheck = date
        do {
            try store.save(settings: settings)
        } catch {
            present(error, title: L("无法保存更新检查时间"))
        }
    }

    /// Shows or hides the host sidebar. Pure UI state, saved on its own so it
    /// does not re-run appearance or transfer configuration.
    func toggleSidebar(_ visible: Bool? = nil) {
        let next = visible ?? !settings.sidebarVisible
        guard next != settings.sidebarVisible else { return }
        settings.sidebarVisible = next
        do {
            try store.save(settings: settings)
        } catch {
            present(error, title: L("无法保存侧边栏状态"))
        }
    }

    /// Switches between the tab strip (one session at a time) and a workspace
    /// tab (multi-pane grid). The setting is remembered so the next launch opens
    /// the same kind of view; switching to a workspace never dials every pane,
    /// it only focuses the workspace so the user can pick which one to connect.
    func toggleBoard(_ enabled: Bool? = nil) {
        let wantsBoard = enabled ?? !isWorkspaceSelected
        let mode = wantsBoard ? "board" : "tabs"
        if settings.navigationMode != mode {
            settings.navigationMode = mode
            do {
                try store.save(settings: settings)
            } catch {
                present(error, title: L("无法保存默认视图"))
            }
        }
        if wantsBoard {
            if boards.isEmpty { restoreBoards() }
            if let id = selectedBoardID ?? currentBoard?.id ?? boards.first?.id {
                openBoardTab(id, connect: false)
            }
        } else if let tab = tabs.first {
            selectTab(tab)
        } else {
            showStartPage()
        }
    }

    func applyAppearance() {
        switch settings.appearance {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    // MARK: - Workspace persistence

    func persistWorkspace() {
        workspaceSaveTask?.cancel()
        let snapshot = WorkspaceSnapshot(tabs: tabs.map { $0.snapshot },
                                         selectedIndex: tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0)
        workspaceSaveTask = Task { [store] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            try? store.save(workspace: snapshot)
        }
    }

    /// Synchronous version of `persistWorkspace`, used while quitting.
    ///
    /// `persistWorkspace` debounces for 300 ms and `NSApp.terminate` does not
    /// wait for that Task, so closing the window used to quit before the last
    /// tab layout reached SQLite. Writes here run on the caller's thread.
    func flushWorkspace() {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = nil
        let selected = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let snapshot = WorkspaceSnapshot(tabs: tabs.map { $0.snapshot }, selectedIndex: selected)
        try? store.save(workspace: snapshot)
    }

    func restoreWorkspace() {
        guard let snapshot = try? store.workspaceSnapshot(), !snapshot.tabs.isEmpty else { return }
        var restored: [TerminalTab] = []
        for saved in snapshot.tabs {
            guard let host = host(id: saved.hostID) else { continue }
            let kind = TabKind(rawValue: saved.kind ?? "") ?? .terminal
            let tab = TerminalTab(kind: kind,
                                  host: host,
                                  localFiles: environment.localFiles,
                                  startRemoteDirectory: saved.lastRemoteDirectory,
                                  localStartDirectory: settings.lastLocalDirectory,
                                  showsSFTP: saved.showsSFTP)
            tab.local.onDirectoryChange = { [weak self] path in self?.recordLocalDirectory(path) }
            configureSFTPHistory(for: tab.remote)
            tab.local.showHidden = settings.showHiddenFiles
            tab.remote.showHidden = settings.showHiddenFiles
            tab.pendingPaneHostIDs = saved.additionalHostIDs ?? []
            restored.append(tab)
        }
        tabs = restored
        if restored.indices.contains(snapshot.selectedIndex) {
            selectedTabID = restored[snapshot.selectedIndex].id
        } else {
            selectedTabID = restored.first?.id
        }
        // Dialing is deferred to connectInitialWorkspace(), once we know whether a
        // workspace tab (which owns its own sessions) is the selected one.
    }

    // MARK: - Transfers

    /// Server-to-server relays run inside this process instead of the transfer
    /// engine, so they need their own cancellation handles.
    var relayTasks: [UUID: Task<Void, Never>] = [:]
    var relayRequests: [UUID: RelayRequest] = [:]

    /// Upsert one progress row. Relays feed this directly; engine transfers
    /// arrive through subscribeToTransfers().
    func updateTransfer(_ progress: TransferProgress) {
        if let index = transfers.firstIndex(where: { $0.id == progress.id }) {
            transfers[index] = progress
        } else {
            transfers.insert(progress, at: 0)
            if transfers.count > 500 {
                transfers.removeLast(transfers.count - 500)
            }
        }
        guard progress.state.isTerminal else { return }
        persistTransfer(progress)
        if let request = relayRequests[progress.id] {
            if progress.state == .completed,
               let tab = transferSessions.first(where: { $0.id == request.tabID }),
               let pane = tab.allRemotes.first(where: { $0.id == request.targetPaneID }) {
                Task { await pane.refresh() }
            }
            if progress.state != .failed {
                relayRequests[progress.id] = nil
            }
        } else {
            refreshAfterTransfer(progress)
        }
    }

    private func subscribeToTransfers() {
        Task { [weak self] in
            guard let self else { return }
            let stream = await self.environment.transferEngine.progressStream()
            for await progress in stream {
                await MainActor.run {
                    if let index = self.transfers.firstIndex(where: { $0.id == progress.id }) {
                        self.transfers[index] = progress
                    } else {
                        self.transfers.insert(progress, at: 0)
                    }
                    if self.transfers.count > 500 {
                        self.transfers.removeLast(self.transfers.count - 500)
                    }
                    if progress.state.isTerminal {
                        self.persistTransfer(progress)
                        self.refreshAfterTransfer(progress)
                    }
                }
            }
        }
    }

    var activeTransferCount: Int {
        transfers.filter { !$0.state.isTerminal }.count
    }

    func cancelTransfer(_ progress: TransferProgress) {
        if let task = relayTasks[progress.id] {
            task.cancel()
            return
        }
        Task {
            await environment.transferEngine.cancel(progress.id)
        }
    }

    func pauseTransfer(_ progress: TransferProgress) {
        if relayTasks[progress.id] != nil {
            presentMessage(L("不能暂停"),
                           L("远端到远端的传输是流式的，不支持暂停。"),
                           suggestion: L("可以取消后重新拖一次。"))
            return
        }
        Task {
            await environment.transferEngine.pause(progress.id)
        }
    }

    func resumeTransfer(_ progress: TransferProgress) {
        guard let client = sftpClient(for: progress.hostID) else { return }
        Task {
            await environment.transferEngine.resume(progress.id, remote: client)
        }
    }

    func retryTransfer(_ progress: TransferProgress) {
        if let request = relayRequests[progress.id],
           let tab = transferSessions.first(where: { $0.id == request.tabID }),
           let source = tab.allRemotes.first(where: { $0.id == request.sourcePaneID }),
           let target = tab.allRemotes.first(where: { $0.id == request.targetPaneID }) {
            removeTransfer(progress)
            copyRemotely(entries: request.entries, from: source, to: target, tab: tab)
            return
        }
        guard let client = sftpClient(for: progress.hostID) else { return }
        Task {
            await environment.transferEngine.retry(progress.id, remote: client)
        }
    }

    func clearFinishedTransfers() {
        try? store.clearFinishedTransfers()
        Task {
            await environment.transferEngine.clearFinished()
            await MainActor.run {
                self.transfers.removeAll { $0.state.isTerminal }
            }
        }
    }

    func removeTransfer(_ progress: TransferProgress) {
        if let task = relayTasks[progress.id] {
            task.cancel()
            relayTasks[progress.id] = nil
        }
        relayRequests[progress.id] = nil
        try? store.deleteTransfer(id: progress.id)
        transfers.removeAll { $0.id == progress.id }
        Task {
            await environment.transferEngine.remove(progress.id)
        }
    }

    func retryAllFailedTransfers() {
        for progress in transfers where progress.state == .failed {
            retryTransfer(progress)
        }
    }

    private var transferSessions: [TerminalTab] {
        let otherBoards = boardSessionCache.filter { $0.key != currentBoard?.id }
        return tabs + boardSessions + otherBoards.flatMap { $0.value.values }
    }

    func sftpClient(for hostID: UUID?) -> SFTPClient? {
        guard let hostID else { return nil }
        return transferSessions.flatMap(\.allRemotes).first { $0.hostID == hostID && $0.isReady }?.client
    }

    func hostName(forTransfer progress: TransferProgress) -> String {
        hostName(for: progress.hostID)
    }

    // MARK: - Errors

    func present(_ error: Error, title: String = L("操作失败")) {
        alert = AppError(error, title: title)
    }

    func presentMessage(_ title: String, _ message: String, suggestion: String? = nil) {
        alert = AppError(title: title, message: message, suggestion: suggestion)
    }

    // MARK: - Prompts

    func submitPassword(_ value: String) {
        passwordPrompt = nil
        let continuation = passwordContinuation
        passwordContinuation = nil
        continuation?.resume(returning: value)
    }

    func cancelPasswordPrompt() {
        passwordPrompt = nil
        let continuation = passwordContinuation
        passwordContinuation = nil
        continuation?.resume(returning: nil)
    }

    func resolveHostKeyPrompt(_ decision: HostKeyDecision) {
        hostKeyPrompt = nil
        let continuation = hostKeyContinuation
        hostKeyContinuation = nil
        continuation?.resume(returning: decision)
    }

    func resolveConflict(_ policy: ConflictPolicy?, applyToAll: Bool) {
        pendingConflict = nil
        if applyToAll { transferConflictPolicy = policy }
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: policy)
    }

    // MARK: - Command palette

    var commandPaletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Workspaces come first: with no tab open this is the keyboard route
        // into a multi-terminal workspace.
        for board in boards.sorted(by: { $0.name < $1.name }) {
            // A workspace is also findable by the machines inside it: typing a
            // host name lists both the host and the workspace that hosts it.
            let paneHosts = board.panes.compactMap { host(id: $0.hostID) }
            let paneKeywords = paneHosts.flatMap { [$0.name, $0.displayAddress, $0.hostname] }
            items.append(CommandPaletteItem(id: "board-" + board.id.uuidString,
                                            title: board.name,
                                            subtitle: L("工作区 · %d 个窗格", board.panes.count),
                                            kind: .action,
                                            host: nil,
                                            action: { [weak self] in self?.openBoardTab(board.id) },
                                            groupTitle: L("工作区"),
                                            keywords: [board.name] + paneKeywords))
        }

        // One row per host. The palette used to add a second "· SFTP" row for
        // every machine, which doubled the list for a destination that already
        // has its own keyboard route: ⌘↩ on the host row, or ⇧⌘T for the host
        // picker. Keeping the list to one row per host also keeps ↑↓ short.
        func appendHost(_ host: SSHHost, groupTitle: String, depth: Int) {
            let keywords = quickOpenKeywords(for: host, groupPath: groupTitle)
            let weight = quickOpenWeight(for: host)
            items.append(CommandPaletteItem(id: "host-" + host.id.uuidString,
                                            title: host.name,
                                            subtitle: host.displayAddress,
                                            kind: .host,
                                            host: host,
                                            action: nil,
                                            groupTitle: groupTitle,
                                            depth: depth,
                                            keywords: keywords,
                                            weight: weight))
        }

        // Walk the group tree so the palette mirrors the sidebar hierarchy:
        // nested groups keep their depth, hosts stay under their own group.
        func walk(_ node: SidebarGroupNode, path: String, depth: Int) {
            let full = path.isEmpty ? node.group.name : path + " / " + node.group.name
            for host in node.hosts {
                // One step in from the section header so a group's rows read as
                // belonging to it.
                appendHost(host, groupTitle: full, depth: depth + 1)
            }
            for child in node.children {
                walk(child, path: full, depth: depth + 1)
            }
        }

        for node in sidebarTree {
            walk(node, path: "", depth: 0)
        }
        for host in ungroupedHosts {
            appendHost(host, groupTitle: L("未分组"), depth: 0)
        }

        let actions: [(String, String, () -> Void)] = [
            (L("新建主机"), "⌘N", { [weak self] in self?.editingHost = SSHHost(name: "", hostname: "") }),
            (L("新建分组…"), "⇧⌘N", { [weak self] in self?.beginNewGroup() }),
            (L("新建工作区…"), "⇧⌘B", { [weak self] in self?.promptCreateBoard() }),
            (L("打开设置"), "⌘,", { [weak self] in self?.showingSettings = true }),
            (L("传输中心"), "⇧⌘J", { [weak self] in self?.showingTransferCenter = true }),
            (L("从 ~/.ssh/config 导入"), "", { [weak self] in self?.importSSHConfig() }),
            (L("从 Termius 导入…"), "", { [weak self] in self?.beginTermiusImport() })
        ]
        for (index, action) in actions.enumerated() {
            items.append(CommandPaletteItem(id: "action-" + String(index),
                                            title: action.0,
                                            subtitle: action.1,
                                            kind: .action,
                                            host: nil,
                                            action: action.2,
                                            groupTitle: L("命令"),
                                            keywords: [action.0, action.1]))
        }
        return items
    }

    /// Everything a host answers to in the quick-open panel: what is written on
    /// the row, plus the address, user, port, group path, tags, notes and the
    /// pinyin forms so "cs" still finds 测试服务器.
    private func quickOpenKeywords(for host: SSHHost, groupPath: String) -> [String] {
        var keywords = [host.name, host.displayAddress, host.hostname, host.username,
                        groupPath, String(host.port), host.notes]
        keywords += host.tags
        keywords.append(Self.latinized(host.name))
        keywords.append(Self.pinyinInitials(host.name))
        return keywords.filter { !$0.isEmpty }
    }

    /// Recent machines come first among equally good matches; the cap keeps a
    /// long-used host from outranking a better textual match.
    private func quickOpenWeight(for host: SSHHost) -> Int {
        var weight = min(max(host.useCount, 0), 20)
        guard let last = host.lastUsedAt else { return weight }
        let days = Date().timeIntervalSince(last) / 86_400
        if days < 1 { weight += 40 } else if days < 7 { weight += 20 } else if days < 30 { weight += 10 }
        return weight
    }

    /// Ranks the quick-open entries against what the user typed.
    ///
    /// An empty query keeps the catalog order (workspaces, then the sidebar
    /// tree, then commands) so opening the panel and pressing return does
    /// something predictable.
    func commandPaletteResults(query: String) -> [CommandPaletteItem] {
        let items = commandPaletteItems
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let candidates = items.map {
            QuickOpen.Candidate(id: $0.id, title: $0.title, keywords: $0.keywords, weight: $0.weight)
        }
        var byID: [String: CommandPaletteItem] = [:]
        for item in items { byID[item.id] = item }
        return QuickOpen.rank(candidates, query: query).compactMap { byID[$0.candidate.id] }
    }

    /// Opens the row the panel highlights. `prefersSFTP` is ⌘↩: a host opens a
    /// browser tab instead of a shell, which is the quicker route to files when
    /// the panel was opened for exactly that. Plain return always opens the
    /// terminal tab — the list no longer carries separate SFTP rows.
    func activateCommand(_ item: CommandPaletteItem, prefersSFTP: Bool = false) {
        showingCommandPalette = false
        if let host = item.host {
            if prefersSFTP {
                openSFTPTab(for: host)
            } else {
                openTab(for: host)
            }
        } else {
            item.action?()
        }
    }
}

// MARK: - Transfer history

extension AppState {
    /// Restores the transfer centre from the catalog so finished transfers survive a restart.
    func loadTransferHistory() {
        guard let records = try? store.transfers() else { return }
        let restored: [TransferProgress] = records.compactMap { record in
            guard record.state.isTerminal else { return nil }
            return TransferProgress(id: record.id,
                                    hostID: record.hostID,
                                    direction: record.direction,
                                    sourcePath: record.sourcePath,
                                    destinationPath: record.destinationPath,
                                    state: record.state,
                                    bytesCompleted: record.completedBytes,
                                    bytesTotal: record.totalBytes,
                                    filesCompleted: 0,
                                    filesTotal: 0,
                                    currentFile: nil,
                                    bytesPerSecond: 0,
                                    errorMessage: record.errorMessage,
                                    attempt: 0,
                                    skippedFiles: 0,
                                    updatedAt: record.updatedAt)
        }
        if !restored.isEmpty {
            transfers = restored
        }
    }

    func persistTransfer(_ progress: TransferProgress) {
        guard let hostID = progress.hostID else { return }
        let record = TransferRecord(id: progress.id,
                                    hostID: hostID,
                                    direction: progress.direction,
                                    sourcePath: progress.sourcePath,
                                    destinationPath: progress.destinationPath,
                                    totalBytes: progress.bytesTotal,
                                    completedBytes: progress.bytesCompleted,
                                    state: progress.state,
                                    errorMessage: progress.errorMessage,
                                    updatedAt: progress.updatedAt)
        try? store.save(transfer: record)
    }

    /// A finished transfer has to be visible in the browser: refresh the pane it landed in,
    /// otherwise the uploaded file only shows up after a manual refresh and the transfer
    /// looks like it did nothing.
    func refreshAfterTransfer(_ progress: TransferProgress) {
        guard progress.state == .completed, let hostID = progress.hostID else { return }
        let directory = POSIXPath.parent(progress.destinationPath)
        switch progress.direction {
        case .upload:
            for pane in transferSessions.flatMap(\.allRemotes)
                where pane.hostID == hostID && pane.isReady && POSIXPath.normalize(pane.path) == directory {
                Task { await pane.refresh() }
            }
        case .download:
            for tab in transferSessions where POSIXPath.normalize(tab.local.path) == directory {
                tab.local.reload()
            }
        }
    }
}
