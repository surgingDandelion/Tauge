import AppKit
import Foundation
import ShellXKit

// MARK: - Transfers

extension AppState {
    func upload(entries: [FileEntry], to tab: TerminalTab, destination: String? = nil, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        Task { @MainActor in
            await self.performUpload(entries: entries, tab: tab, destination: destination, pane: target)
        }
    }

    private func performUpload(entries: [FileEntry], tab: TerminalTab, destination: String?, pane: RemoteBrowserModel) async {
        var client = pane.client
        if client == nil {
            await openSFTP(tab: tab, pane: pane)
            client = pane.client
        }
        guard let client else {
            presentMessage(L("无法上传"),
                           L("SFTP 会话尚未建立，请先在标签中打开 SFTP 面板并确认连接正常。"),
                           suggestion: L("使用 ⇧⌘O 打开 SFTP；若连接失败，状态栏会显示原因。"))
            return
        }
        let destinationDirectory = destination ?? pane.path
        guard let policy = await uploadConflictPolicy(entries: entries, directory: destinationDirectory, client: client) else { return }
        for entry in entries {
            let target = POSIXPath.join(destinationDirectory, entry.name)
            let item = TransferItem(hostID: tab.hostID,
                                    direction: .upload,
                                    sourcePath: entry.path,
                                    destinationPath: target,
                                    recursive: entry.kind == .directory,
                                    conflictPolicy: policy)
            _ = await environment.transferEngine.enqueue(item, remote: client)
        }
    }

    private func uploadConflictPolicy(entries: [FileEntry], directory: String, client: SFTPClient) async -> ConflictPolicy? {
        if let override = transferConflictPolicy { return override }
        if settings.conflictPolicy != "ask" {
            return Self.conflictPolicy(fromSetting: settings.conflictPolicy)
        }
        // Only interrupt the user when something would actually be overwritten.
        var hasConflict = false
        for entry in entries.prefix(20) {
            if (try? await client.stat(POSIXPath.join(directory, entry.name))) != nil {
                hasConflict = true
                break
            }
        }
        if !hasConflict { return .overwrite }
        return await askConflictPolicy(fileCount: entries.count)
    }

    func download(entries: [FileEntry], from tab: TerminalTab, destination: String? = nil, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        Task { @MainActor in
            await self.performDownload(entries: entries, tab: tab, destination: destination, pane: target)
        }
    }

    /// Opt-in stderr trace (`SHELLX_TRACE_TRANSFERS=1`) for diagnosing drag
    /// and drop problems on a machine without a debugger attached.
    func traceTransfer(_ message: String) {
        guard ProcessInfo.processInfo.environment["SHELLX_TRACE_TRANSFERS"] == "1" else { return }
        FileHandle.standardError.write(Data(("[xfer] " + message + "\n").utf8))
    }

    /// Resolve which remote pane a dragged remote path belongs to. The cached
    /// listing may have been refreshed since the drag started, so fall back to
    /// the pane whose directory contains the path, then to the first ready pane.
    func remotePane(forDroppedPath path: String,
                    in tab: TerminalTab,
                    preferringHost hostID: UUID? = nil) -> RemoteBrowserModel? {
        let remotes = tab.allRemotes
        if let hostID, let pane = remotes.first(where: { $0.hostID == hostID }) {
            let contains = pane.path == "/" ? path.hasPrefix("/") : path.hasPrefix(pane.path + "/")
            if contains || remotes.filter({ $0.hostID == hostID }).count == 1 { return pane }
        }
        let containing = remotes
            .filter { $0.path == "/" ? path.hasPrefix("/") : path.hasPrefix($0.path + "/") }
            .sorted { $0.path.count > $1.path.count }
        if let pane = containing.first { return pane }
        if let pane = remotes.first(where: { $0.entries.contains { $0.path == path } }) { return pane }
        return remotes.first(where: { $0.isReady }) ?? remotes.first
    }

    /// Drop of a remote item onto the local pane. Unlike the context menu path
    /// this must work even when the path is no longer in the cached listing —
    /// otherwise the drop silently does nothing and drag and drop feels broken.
    func downloadDroppedPath(_ path: String,
                             into tab: TerminalTab,
                             destination: String,
                             preferringHost hostID: UUID? = nil) {
        traceTransfer("drop path=" + path + " -> " + destination + " host=" + (hostID?.uuidString ?? "-"))
        Task { @MainActor in
            guard let pane = self.remotePane(forDroppedPath: path, in: tab, preferringHost: hostID) else {
                self.presentMessage(L("无法下载"),
                                    L("这条路径来自已经关闭的远端面板。"),
                                    suggestion: L("重新打开远端面板后再拖拽。"))
                return
            }
            var client = pane.client
            if client == nil {
                await self.openSFTP(tab: tab, pane: pane)
                client = pane.client
            }
            guard let client else {
                self.presentMessage(L("无法下载"),
                                    pane.connectionError ?? L("SFTP 会话尚未建立，请先在远端面板上点“重试”。"),
                                    suggestion: L("确认远端面板已连接后再拖拽。"))
                return
            }
            if let entry = pane.entries.first(where: { $0.path == path }) {
                self.traceTransfer("using cached entry (kind=" + entry.kind.rawValue + ")")
                await self.performDownload(entries: [entry], tab: tab, destination: destination, pane: pane)
                return
            }
            self.traceTransfer("stat fallback via " + pane.hostName)
            do {
                let attributes = try await client.stat(path)
                let kind: FileEntry.Kind = attributes.isDirectory ? .directory
                    : (attributes.isSymlink ? .symlink : .file)
                let entry = FileEntry(path: path,
                                      name: (path as NSString).lastPathComponent,
                                      kind: kind,
                                      size: Int64(attributes.size ?? 0),
                                      mode: attributes.permissions.map { UInt16($0 & 0o7777) },
                                      modified: attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                await self.performDownload(entries: [entry], tab: tab, destination: destination, pane: pane)
            } catch {
                self.presentMessage(L("无法下载"),
                                    self.describe(error),
                                    suggestion: L("确认远端路径仍然存在。"))
            }
        }
    }

    private func performDownload(entries: [FileEntry], tab: TerminalTab, destination: String?, pane: RemoteBrowserModel) async {
        var client = pane.client
        if client == nil {
            await openSFTP(tab: tab, pane: pane)
            client = pane.client
        }
        guard let client else {
            presentMessage(L("无法下载"),
                           L("SFTP 会话尚未建立，请先在标签中打开 SFTP 面板并确认连接正常。"),
                           suggestion: L("使用 ⇧⌘O 打开 SFTP；若连接失败，状态栏会显示原因。"))
            return
        }
        let directory = destination ?? tab.local.path
        var policy: ConflictPolicy
        if let override = transferConflictPolicy {
            policy = override
        } else if settings.conflictPolicy == "ask" {
            let fm = FileManager.default
            let conflict = entries.contains { fm.fileExists(atPath: POSIXPath.join(directory, $0.name)) }
            if conflict {
                guard let chosen = await askConflictPolicy(fileCount: entries.count) else { return }
                policy = chosen
            } else {
                policy = .overwrite
            }
        } else {
            policy = Self.conflictPolicy(fromSetting: settings.conflictPolicy)
        }
        for entry in entries {
            let target = POSIXPath.join(directory, entry.name)
            let item = TransferItem(hostID: tab.hostID,
                                    direction: .download,
                                    sourcePath: entry.path,
                                    destinationPath: target,
                                    recursive: entry.kind == .directory,
                                    conflictPolicy: policy)
            _ = await environment.transferEngine.enqueue(item, remote: client)
        }
    }

    /// Drag and drop from Finder onto the terminal or the SFTP pane.
    func uploadDropped(urls: [URL], to tab: TerminalTab, destination: String? = nil, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        Task { @MainActor in
            var entries: [FileEntry] = []
            for url in urls {
                if let entry = try? environment.localFiles.entry(for: url.path) {
                    entries.append(entry)
                }
            }
            guard !entries.isEmpty else {
                self.presentMessage(L("无法上传"),
                                    L("拖拽的内容不是可读取的本地文件或目录。"),
                                    suggestion: L("从 Finder 拖拽文件，或使用面板上的“上传”按钮。"))
                return
            }
            await self.performUpload(entries: entries, tab: tab, destination: destination, pane: target)
        }
    }

    /// Asks the user how to resolve name collisions. Times out after a minute so
    /// a prompt that never appears can never stall the transfer queue.
    func askConflictPolicy(fileCount: Int, timeoutSeconds: Double = 60) async -> ConflictPolicy? {
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.conflictContinuation != nil else { return }
            self.resolveConflict(nil, applyToAll: false)
            self.presentMessage(L("冲突处理已超时"),
                                L("没有收到冲突处理方式，传输已取消。"),
                                suggestion: L("重新拖拽或点击上传即可再次触发。"))
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            self.conflictContinuation = continuation
            self.pendingConflict = PendingConflict(title: L("目标位置已存在同名文件"),
                                                   message: L("共有 ") + String(fileCount) + L(" 个项目需要传输，请选择冲突处理方式。"),
                                                   fileCount: fileCount)
        }
    }

    static func conflictPolicy(fromSetting value: String) -> ConflictPolicy {
        switch value {
        case "overwrite": return .overwrite
        case "skip": return .skip
        case "onlyIfNewer": return .onlyIfNewer
        case "rename": return .rename
        default: return .overwrite
        }
    }

    // MARK: - Remote file operations

    func refreshBrowser(_ tab: TerminalTab, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        Task { await target.refresh() }
    }

    func createRemoteFolder(in tab: TerminalTab, name: String, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard let client = target.client else { return }
        Task {
            do {
                try await client.createDirectory(POSIXPath.join(target.path, name))
                await target.refresh()
            } catch {
                await MainActor.run { self.present(error, title: L("新建文件夹失败")) }
            }
        }
    }

    func createRemoteFile(in tab: TerminalTab, name: String, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard let client = target.client else { return }
        let path = POSIXPath.join(target.path, name)
        Task {
            do {
                try await client.writeFile(path, data: Data())
                await target.refresh()
            } catch {
                await MainActor.run { self.present(error, title: L("新建文件失败")) }
            }
        }
    }

    func renameRemote(_ entry: FileEntry, in tab: TerminalTab, to newName: String, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard let client = target.client else { return }
        let newPath = POSIXPath.join(target.path, newName)
        Task {
            do {
                try await client.rename(entry.path, to: newPath)
                await target.refresh()
            } catch {
                await MainActor.run { self.present(error, title: L("重命名失败")) }
            }
        }
    }

    func deleteRemote(_ entries: [FileEntry], in tab: TerminalTab, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard let client = target.client else { return }
        Task {
            for entry in entries {
                do {
                    if entry.kind == .directory {
                        try await client.removeDirectory(entry.path)
                    } else {
                        try await client.removeFile(entry.path)
                    }
                } catch {
                    await MainActor.run { self.present(error, title: L("删除 ") + entry.name + L(" 失败")) }
                    break
                }
            }
            await target.refresh()
        }
    }

    func setRemotePermissions(_ entry: FileEntry, in tab: TerminalTab, mode: UInt16, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard let client = target.client else { return }
        Task {
            do {
                try await client.setPermissions(entry.path, mode: mode)
                await target.refresh()
            } catch {
                await MainActor.run { self.present(error, title: L("修改权限失败")) }
            }
        }
    }

    func createLocalFolder(in tab: TerminalTab, name: String) {
        do {
            try environment.localFiles.createDirectory(at: POSIXPath.join(tab.local.path, name))
            tab.local.reload()
        } catch {
            present(error, title: L("新建文件夹失败"))
        }
    }

    func createLocalFile(in tab: TerminalTab, name: String) {
        do {
            try environment.localFiles.createEmptyFile(at: POSIXPath.join(tab.local.path, name))
            tab.local.reload()
        } catch {
            present(error, title: L("新建文件失败"))
        }
    }

    func renameLocal(_ entry: FileEntry, in tab: TerminalTab, to newName: String) {
        do {
            try environment.localFiles.rename(entry.path, to: POSIXPath.join(tab.local.path, newName))
            tab.local.reload()
        } catch {
            present(error, title: L("重命名失败"))
        }
    }

    func deleteLocal(_ entries: [FileEntry], in tab: TerminalTab) {
        for entry in entries {
            do {
                try environment.localFiles.remove(at: entry.path, recursive: entry.kind == .directory)
            } catch {
                present(error, title: L("删除 ") + entry.name + L(" 失败"))
                break
            }
        }
        tab.local.reload()
    }

    // MARK: - Built-in editor

    func openEditor(_ entry: FileEntry, in tab: TerminalTab, pane: RemoteBrowserModel? = nil) {
        let target = pane ?? tab.remote
        guard entry.kind == .file else { return }
        guard entry.size <= Int64(settings.editorMaxFileSize) else {
            presentMessage(L("文件过大"), L("该文件超过内置编辑器上限（") + String(settings.editorMaxFileSize / 1024 / 1024) + " MB）。",
                           suggestion: L("请使用外部编辑器或先把文件下载到本地。"))
            return
        }
        guard let client = target.client else { return }
        Task {
            do {
                let data = try await client.readFile(entry.path)
                var text = String(data: data, encoding: .utf8)
                if text == nil {
                    text = String(data: data, encoding: tab.encoding.stringEncoding)
                }
                guard let text else {
                    await MainActor.run {
                        self.presentMessage(L("无法预览"), L("该文件不是文本文件或以不支持的编码保存。"))
                    }
                    return
                }
                await MainActor.run {
                    self.editor = EditorContext(tabID: tab.id, paneID: target.id, path: entry.path, text: text)
                }
            } catch {
                await MainActor.run { self.present(error, title: L("读取文件失败")) }
            }
        }
    }

    func saveEditor() {
        guard let context = editor, let tab = tabs.first(where: { $0.id == context.tabID }) else { return }
        let pane = tab.allRemotes.first(where: { $0.id == context.paneID }) ?? tab.remote
        guard let client = pane.client else { return }
        let data = Data(context.text.utf8)
        Task {
            do {
                try await client.writeFile(context.path, data: data)
                await MainActor.run {
                    self.editor = nil
                    self.presentMessage(L("已保存"), L("文件 ") + context.path + L(" 已写入远端。"))
                }
                await pane.refresh()
            } catch {
                await MainActor.run { self.present(error, title: L("保存失败")) }
            }
        }
    }

    // MARK: - Catalog import / export

    func exportCatalog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "shellx-catalog.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportCatalog()
            try data.write(to: url)
        } catch {
            present(error, title: L("导出失败"))
        }
    }

    func importCatalog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try store.importCatalog(data: data)
            reloadCatalog()
            presentMessage(L("导入完成"), L("已合并 ") + url.lastPathComponent + L(" 中的主机、分组与代理。"))
        } catch {
            present(error, title: L("导入失败"))
        }
    }

    /// Imports aliases from ~/.ssh/config, resolving ProxyJump chains between
    /// newly created hosts. Wildcard-only entries (Host *) are used as defaults
    /// but never created as hosts.
    func importSSHConfig() {
        showingImportSheet = false
        do {
            let entries = try SSHConfigParser.load()
            var configGroup = groups.first { $0.name == "SSH Config" }
            if configGroup == nil {
                let group = HostGroup(name: "SSH Config", sortIndex: groups.count)
                try store.save(group: group)
                configGroup = group
            }
            guard let groupID = configGroup?.id else { return }

            var existing = Set(hosts.map { $0.name.lowercased() })
            var created: [String: UUID] = [:]
            var imported: [SSHHost] = []

            var aliases: [String] = []
            for entry in entries {
                if let alias = SSHConfigHost(patterns: entry.patterns).concreteAliases.first {
                    aliases.append(alias)
                }
            }
            for alias in aliases where !alias.contains("*") && !alias.contains("?") {
                guard !existing.contains(alias.lowercased()) else { continue }
                guard let effective = SSHConfigParser.effective(for: alias, in: entries) else { continue }
                var host = SSHHost(groupID: groupID,
                                   name: alias,
                                   hostname: effective.hostName ?? alias,
                                   port: effective.port ?? 22,
                                   username: effective.user ?? "",
                                   authMethod: .privateKey)
                host.identityFilePath = effective.identityFiles.first
                host.keepaliveSeconds = effective.serverAliveInterval
                if effective.identityFiles.isEmpty {
                    host.authMethod = .password
                }
                if let command = effective.proxyCommand, !command.isEmpty {
                    host.notes = L("ProxyCommand 暂不支持：") + command
                }
                created[alias.lowercased()] = host.id
                imported.append(host)
                existing.insert(alias.lowercased())
            }

            for index in imported.indices {
                let alias = imported[index].name.lowercased()
                guard let effective = SSHConfigParser.effective(for: imported[index].name, in: entries),
                      let proxyJump = effective.proxyJump, !proxyJump.isEmpty else { continue }
                let names = proxyJump.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                var ids: [UUID] = []
                for name in names {
                    let key = name.contains("@") ? String(name.split(separator: "@").last ?? "") : name
                    if let id = created[key.lowercased()] {
                        ids.append(id)
                    } else if let existingHost = hosts.first(where: { $0.name.lowercased() == key.lowercased() }) {
                        ids.append(existingHost.id)
                    }
                }
                if !ids.isEmpty {
                    imported[index].jumpPolicy = .hosts(ids)
                }
                _ = alias
            }

            for host in imported {
                try store.save(host: host)
            }
            reloadCatalog()
            presentMessage(L("导入完成"), imported.isEmpty ? L("没有发现新的 SSH 配置别名。") : L("已导入 ") + String(imported.count) + L(" 台主机。"))
        } catch {
            present(error, title: L("读取 ~/.ssh/config 失败"))
        }
    }
}
