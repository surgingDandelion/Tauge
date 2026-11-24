import Foundation
import TaugeKit

/// Remote (SFTP) pane state. One instance per tab, shared with the transfer
/// engine so a finished upload can refresh the list.
@MainActor
final class RemoteBrowserModel: ObservableObject, Identifiable {
    /// Stable identity so several remote panes can live side by side.
    let id = UUID()
    /// The host this pane talks to, and its display name.
    @Published var hostID: UUID?
    @Published var hostName: String = L("远端")
    /// One-time starting directory requested when the pane was added.
    var startDirectory: String?
    /// A directory the current pane has successfully listed, including before a reconnect.
    private(set) var openedDirectory: String?
    @Published var isConnecting = false
    @Published var connectionError: String?
    @Published var path: String = "."
    @Published private(set) var entries: [FileEntry] = [] {
        didSet { rebuildSortedEntries() }
    }
    @Published var sort = FileSortOrder(field: .name, ascending: true) {
        didSet { rebuildSortedEntries() }
    }
    @Published var showHidden = false {
        didSet { rebuildSortedEntries() }
    }
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var selection: Set<String> = []
    /// Row that anchors ⇧ range selection; cleared whenever the pane navigates.
    private(set) var selectionAnchor: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var pathEditing = false

    /// Called after opening a directory or moving through navigation history.
    var onDirectoryChange: ((String) -> Void)?

    private(set) var client: SFTPClient?
    private var history: [String] = []
    private var historyIndex = -1
    private var loadGeneration = 0

    private enum Navigation {
        case attach
        case visit
        case history(Int)
        case refresh
    }

    private(set) var sortedEntries: [FileEntry] = []

    private func rebuildSortedEntries() {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        sortedEntries = sort.sorted(visible)
    }

    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        guard path != "/" else { return result }
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/" + component
            result.append((String(component), accumulated))
        }
        return result
    }

    var isReady: Bool { client != nil }

    func setClient(_ client: SFTPClient?) {
        guard self.client !== client else { return }
        loadGeneration += 1
        isLoading = false
        self.client = client
    }

    /// Applies a click on one row: plain replaces, ⌘ toggles, ⇧ extends from the
    /// anchor. The order comes from the list so ranges follow what is on screen.
    func selectRow(_ path: String, in order: [FileEntry], command: Bool, shift: Bool) {
        let outcome = FileSelection.outcome(clicked: path,
                                            order: order.map(\.path),
                                            selection: selection,
                                            anchor: selectionAnchor,
                                            mode: FileSelection.Mode(command: command, shift: shift))
        selection = outcome.selection
        selectionAnchor = outcome.anchor
    }

    func attach(client: SFTPClient, startDirectory: String?, defaultDirectory: String?) async {
        setClient(client)
        connectionError = nil
        // A remembered folder can disappear between sessions. Try the host's
        // configured start directory and then the server's login directory.
        var seen: Set<String> = []
        let paths = [startDirectory, defaultDirectory, "."].compactMap { $0 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        await load(paths, navigation: .attach)
    }

    func detach() {
        setClient(nil)
        entries = []
        selection.removeAll()
        selectionAnchor = nil
    }

    /// Navigates to a path typed into the address bar (absolute, relative or ~).
    func goTo(_ typed: String) async {
        var target = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if target.hasPrefix("~") {
            let generation = loadGeneration
            if let home = try? await client?.realPath(".") {
                target = home + target.dropFirst()
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }
        if !target.hasPrefix("/") {
            target = POSIXPath.join(path, target)
        }
        await load([target], navigation: .visit)
    }

    private func load(_ paths: [String], navigation: Navigation) async {
        guard let client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorText = nil
        defer { if generation == loadGeneration { isLoading = false } }
        for (index, target) in paths.enumerated() {
            do {
                let names = try await client.listDirectory(target)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                let resolved = target.hasPrefix("/") ? target : (try? await client.realPath(target)) ?? target
                guard generation == loadGeneration, !Task.isCancelled else { return }
                updateDirectory(resolved, entries: names, navigation: navigation)
                return
            } catch {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                if index < paths.count - 1,
                   let error = error as? SFTPError, case .status(let status) = error,
                   [.noSuchFile, .permissionDenied, .failure].contains(status.code) {
                    continue
                }
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
    }

    private func updateDirectory(_ directory: String, entries names: [SFTPNameEntry], navigation: Navigation) {
        let previousDirectory = openedDirectory
        if path != directory {
            // Rows from the old folder no longer exist here.
            selection.removeAll()
            selectionAnchor = nil
        }
        path = directory
        openedDirectory = directory
        startDirectory = nil
        entries = names.compactMap { Self.fileEntry(base: directory, name: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch navigation {
        case .attach where previousDirectory == directory:
            return
        case .attach, .visit:
            if historyIndex < history.count - 1 {
                history = Array(history.prefix(historyIndex + 1))
            }
            if history.last != directory {
                history.append(directory)
                historyIndex = history.count - 1
            }
        case .history(let index):
            historyIndex = index
        case .refresh:
            return
        }
        updateHistoryFlags()
        onDirectoryChange?(directory)
    }

    func refresh() async {
        guard !isLoading else { return }
        await load([path], navigation: .refresh)
    }

    func open(_ entry: FileEntry) async {
        guard entry.isDirectory else { return }
        await load([entry.path], navigation: .visit)
    }

    func goUp() async {
        guard path != "/" else { return }
        let parent = POSIXPath.parent(path)
        await load([parent], navigation: .visit)
    }

    func goBack() async {
        guard historyIndex > 0 else { return }
        let index = historyIndex - 1
        await load([history[index]], navigation: .history(index))
    }

    func goForward() async {
        guard historyIndex + 1 < history.count else { return }
        let index = historyIndex + 1
        await load([history[index]], navigation: .history(index))
    }

    private func updateHistoryFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex + 1 < history.count
    }

    func uniqueRemoteDestination(for name: String) async -> String {
        guard let client else { return POSIXPath.join(path, name) }
        let existing = Set(entries.map { $0.name })
        let candidate = POSIXPath.join(path, POSIXPath.uniqueName(for: name, existing: existing))
        if (try? await client.stat(candidate)) == nil { return candidate }
        // Extremely rare: the remote list was stale. Fall back to a timestamped name.
        let stamp = Int(Date().timeIntervalSince1970)
        return POSIXPath.join(path, POSIXPath.uniqueName(for: name, existing: existing.union([name + "." + String(stamp)])))
    }

    static func fileEntry(base: String, name: SFTPNameEntry) -> FileEntry? {
        guard POSIXPath.isChildComponent(name.filename) else { return nil }
        let attributes = name.attributes
        let permissions = attributes.permissions ?? 0
        let kind: FileEntry.Kind
        if attributes.isDirectory {
            kind = .directory
        } else if attributes.isSymlink {
            kind = .symlink
        } else if permissions & 0o170000 == 0o100000 || permissions == 0 {
            kind = .file
        } else {
            kind = .other
        }
        let separator = base.isEmpty || base.hasSuffix("/") ? "" : "/"
        let fullPath = base + separator + name.filename
        return FileEntry(path: fullPath,
                         name: name.filename,
                         kind: kind,
                         size: Int64(attributes.size ?? 0),
                         mode: UInt16(permissions & 0o7777),
                         owner: attributes.uid.map { "#" + String($0) },
                         group: attributes.gid.map { "#" + String($0) },
                         modified: attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                         linkTarget: nil,
                         isHidden: name.filename.hasPrefix("."))
    }
}

/// Local pane state. Kept in lockstep with the remote pane's sorting and
/// hidden-file preferences so the two lists read the same way.
@MainActor
final class LocalBrowserModel: ObservableObject {
    @Published var path: String
    @Published private(set) var entries: [FileEntry] = [] {
        didSet { rebuildSortedEntries() }
    }
    @Published var sort = FileSortOrder(field: .name, ascending: true) {
        didSet { rebuildSortedEntries() }
    }
    @Published var showHidden = false {
        didSet { rebuildSortedEntries() }
    }
    @Published var errorText: String?
    @Published var selection: Set<String> = []
    /// Row that anchors ⇧ range selection; cleared whenever the pane navigates.
    private(set) var selectionAnchor: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// Called whenever the pane navigates to a new local folder.
    var onDirectoryChange: ((String) -> Void)?

    private let service: LocalFileService
    private var history: [String] = []
    private var historyIndex = -1

    init(service: LocalFileService, startDirectory: String? = nil) {
        self.service = service
        let start = startDirectory ?? LocalFileService.defaultStartDirectory
        self.path = start
        history = [start]
        historyIndex = 0
        reload()
    }

    private(set) var sortedEntries: [FileEntry] = []

    private func rebuildSortedEntries() {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        sortedEntries = sort.sorted(visible)
    }

    var breadcrumbs: [(name: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated += "/" + component
            result.append((String(component), accumulated))
        }
        return result
    }

    func reload() {
        do {
            entries = try service.list(directory: path, showHidden: true)
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func load(_ newPath: String, recordHistory: Bool = true) {
        guard service.isDirectory(newPath) else { return }
        let previousPath = path
        path = newPath
        if newPath != previousPath {
            // Rows from the old folder no longer exist here.
            selection.removeAll()
            selectionAnchor = nil
        }
        if recordHistory {
            if historyIndex < history.count - 1 {
                history = Array(history.prefix(historyIndex + 1))
            }
            if history.last != newPath {
                history.append(newPath)
                historyIndex = history.count - 1
            }
            updateHistoryFlags()
            onDirectoryChange?(newPath)
        }
        reload()
    }

    func open(_ entry: FileEntry) {
        guard entry.isDirectory else { return }
        load(entry.path)
    }

    /// Applies a click on one row: plain replaces, ⌘ toggles, ⇧ extends from the
    /// anchor. The order comes from the list so ranges follow what is on screen.
    func selectRow(_ path: String, in order: [FileEntry], command: Bool, shift: Bool) {
        let outcome = FileSelection.outcome(clicked: path,
                                            order: order.map(\.path),
                                            selection: selection,
                                            anchor: selectionAnchor,
                                            mode: FileSelection.Mode(command: command, shift: shift))
        selection = outcome.selection
        selectionAnchor = outcome.anchor
    }

    func goUp() {
        guard path != "/" else { return }
        load(POSIXPath.parent(path))
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        updateHistoryFlags()
        load(history[historyIndex], recordHistory: false)
    }

    func goForward() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        updateHistoryFlags()
        load(history[historyIndex], recordHistory: false)
    }

    private func updateHistoryFlags() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex + 1 < history.count
    }

    func attributeSizeAndDate(of entry: FileEntry) -> (size: Int64, modified: Date)? {
        service.attributes(of: entry.path)
    }

    /// Navigates to a path typed into the address bar (absolute, relative or ~).
    func goTo(_ typed: String) {
        var target = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        if target.hasPrefix("~") { target = (target as NSString).expandingTildeInPath }
        if !target.hasPrefix("/") { target = POSIXPath.join(path, target) }
        guard service.isDirectory(target) else {
            errorText = L("目录不存在：") + target
            return
        }
        load(target)
    }
}
