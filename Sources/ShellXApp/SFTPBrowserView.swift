import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ShellXKit

struct SFTPBrowserView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab

    /// Two panes plus a divider need at least this much width; a board pane is
    /// usually narrower, and HSplitView used to overflow its container when the
    /// children's minWidth exceeded the available space, clipping the remote
    /// pane down to a sliver.
    private static let compactWidth: CGFloat = 700

    /// Below this width a pane stops showing the size and date columns: at
    /// 200pt only the file name is legible, and truncating "R...(1)" instead of
    /// "Report (1).pdf" is worse than hiding information that has a tooltip.
    private static let narrowPaneWidth: CGFloat = 330

    private enum CompactSide: Hashable {
        case local
        case remote(UUID)
    }

    @ViewState private var compactSide: CompactSide?

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if proxy.size.width < Self.compactWidth {
                    compactSwitcher
                    Divider().opacity(0.5)
                    compactContent
                } else {
                    HSplitView {
                        DropArea(app: app, onDrop: handleLocalDrop) {
                            PaneWidthReader { width in
                                LocalBrowserPane(model: tab.local, tab: tab, isCompact: width < Self.narrowPaneWidth)
                            }
                        }
                        .frame(minWidth: 200)
                        ForEach(tab.allRemotes) { pane in
                            DropArea(app: app, onDrop: { handleRemoteDrop($0, on: pane) }) {
                                PaneWidthReader { width in
                                    RemoteBrowserPane(model: pane, tab: tab, isCompact: width < Self.narrowPaneWidth)
                                }
                            }
                            .frame(minWidth: 200)
                        }
                    }
                    .frame(minHeight: 160)
                }
                TransferActivityBar(tab: tab)
            }
        }
        .frame(minHeight: 0)
        .clipped()
        // Clicking anywhere in the file panel (empty area, toolbar, a row)
        // also makes that board pane the active one; clicks that a control
        // consumes still fire this simultaneous gesture.
        .simultaneousGesture(TapGesture().onEnded {
            guard app.isWorkspaceSelected else { return }
            app.focusBoardPane(tab.id)
        })
    }

    /// Narrow layout: one full-width browser at a time instead of two clipped ones.
    private var resolvedCompactSide: CompactSide {
        if let compactSide {
            switch compactSide {
            case .local:
                return .local
            case .remote(let id):
                if tab.allRemotes.contains(where: { $0.id == id }) { return compactSide }
            }
        }
        return .remote(tab.remote.id)
    }

    private var compactSwitcher: some View {
        HStack(spacing: 4) {
            compactChip(title: L("本地"), symbol: "folder", side: .local)
            ForEach(tab.allRemotes) { pane in
                compactChip(title: pane.hostName, symbol: "externaldrive.connected.to.line.below", side: .remote(pane.id))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelBackground)
    }

    private func compactChip(title: String, symbol: String, side: CompactSide) -> some View {
        let selected = resolvedCompactSide == side
        return Button {
            compactSide = side
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 10.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Theme.accent : Theme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var compactContent: some View {
        switch resolvedCompactSide {
        case .local:
            DropArea(app: app, onDrop: handleLocalDrop) {
                LocalBrowserPane(model: tab.local, tab: tab, isCompact: true)
            }
        case .remote(let id):
            if let pane = tab.allRemotes.first(where: { $0.id == id }) {
                DropArea(app: app, onDrop: { handleRemoteDrop($0, on: pane) }) {
                    RemoteBrowserPane(model: pane, tab: tab, isCompact: true)
                }
            } else {
                LocalBrowserPane(model: tab.local, tab: tab, isCompact: true)
            }
        }
    }

    /// Drops on the local pane always land in its directory.
    private func handleLocalDrop(_ content: DroppedContent) {
        app.traceTransfer("drop local: " + String(content.remotePaths.count) + " remote path(s), "
                          + String(content.localURLs.count) + " local url(s)")
        // A multi-row drag arrives as one batch: one conflict question, and the
        // panes involved can reconnect before the transfer starts.
        app.downloadDroppedPaths(droppedItems(content), into: tab, destination: tab.local.path)
    }

    /// Drops on a remote pane: Finder files upload there, remote items are
    /// relayed from the pane they came from (server to server).
    private func handleRemoteDrop(_ content: DroppedContent, on pane: RemoteBrowserModel) {
        app.traceTransfer("drop remote " + pane.hostName + ": " + String(content.remotePaths.count) + " remote path(s), "
                          + String(content.localURLs.count) + " local url(s)")
        if !content.localURLs.isEmpty {
            app.uploadDropped(urls: content.localURLs, to: tab, destination: pane.path, pane: pane)
        }
        app.copyDroppedPaths(droppedItems(content), in: tab, to: pane)
    }

    private func droppedItems(_ content: DroppedContent) -> [(path: String, hostID: UUID?, paneID: UUID?)] {
        content.remotePaths.map { item in
            (path: item.path,
             hostID: item.hostID.flatMap { UUID(uuidString: $0) },
             paneID: item.paneID.flatMap { UUID(uuidString: $0) })
        }
    }
}

/// Preview under the pointer while dragging: showing the selection size makes it
/// obvious that a multi-row drag moves every selected row, not just the one that
/// was grabbed.
private func dragPreviewRow(for entry: FileEntry, count: Int) -> some View {
    HStack(spacing: 4) {
        Image(systemName: entry.isDirectory ? "folder" : "doc")
            .font(.system(size: 11))
            .foregroundStyle(Theme.accent)
        Text(entry.name)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
        if count > 1 {
            Text("+" + String(count - 1))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Theme.panelBackground)
    .clipShape(RoundedRectangle(cornerRadius: 6))
}

// MARK: - Local pane

struct LocalBrowserPane: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: LocalBrowserModel
    @ObservedObject var tab: TerminalTab
    /// True inside a narrow board pane, where the wide toolbar would be clipped.
    var isCompact: Bool = false
    @ViewState private var pathText = ""

    private var uploadTarget: RemoteBrowserModel {
        tab.allRemotes.first(where: { $0.isReady }) ?? tab.remote
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            FileListHeader(showsDetails: !isCompact)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sortedEntries) { entry in
                        FileRowView(entry: entry, isSelected: model.selection.contains(entry.path), showsDetails: !isCompact)
                            .contentShape(Rectangle())
                            // Drag must be installed before the tap gestures,
                            // otherwise SwiftUI keeps the row in a tap sequence
                            // and no drag session ever begins.
                            .onDrag({
                                LocalFileDrag.itemProvider(entries: dragEntries(grabbed: entry,
                                                                                in: model.sortedEntries,
                                                                                selected: model.selection),
                                                           grabbed: entry)
                            }, preview: {
                                dragPreviewRow(for: entry,
                                               count: dragEntries(grabbed: entry,
                                                                  in: model.sortedEntries,
                                                                  selected: model.selection).count)
                            })
                            .onTapGesture(count: 2) { open(entry) }
                            .onTapGesture { select(entry) }
                            .contextMenu { menu(for: entry) }
                    }
                }
            }
            Divider()
            footer
        }
        .background(Theme.panelBackground)
        .onAppear { pathText = model.path }
        .onChange(of: model.path) { pathText = $0 }
    }

    private var toolbar: some View {
        PaneHeader {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
            Text(L("本地"))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 3)
            Text((model.path as NSString).lastPathComponent.isEmpty ? "/" : (model.path as NSString).lastPathComponent)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            // Panes get as narrow as 200pt when several servers share a window,
            // so the header lays itself out instead of trusting a fixed width:
            // the full control set is used when it fits, otherwise only the
            // actions used constantly stay and the rest move into a menu.
            ViewThatFits(in: .horizontal) {
                localWideControls
                localCompactControls
            }
        }
    }

    private var localWideControls: some View {
        HStack(spacing: 1) {
            PaneIconButton(systemName: "chevron.backward", help: L("后退"), isEnabled: model.canGoBack) { model.goBack() }
            PaneIconButton(systemName: "chevron.forward", help: L("前进"), isEnabled: model.canGoForward) { model.goForward() }
            PaneIconButton(systemName: "arrow.up", help: L("上级目录")) { model.goUp() }
            PaneIconButton(systemName: "arrow.clockwise", help: L("刷新")) { model.reload() }
            PaneDividerLine()
            localSortMenu
            PaneIconButton(systemName: model.showHidden ? "eye.fill" : "eye",
                           help: L("显示隐藏文件"),
                           isOn: model.showHidden) { model.showHidden.toggle() }
            PaneDividerLine()
            uploadButton
        }
    }

    private var localCompactControls: some View {
        HStack(spacing: 1) {
            PaneIconButton(systemName: "arrow.up", help: L("上级目录")) { model.goUp() }
            PaneIconButton(systemName: "arrow.clockwise", help: L("刷新")) { model.reload() }
            localOverflowMenu
            uploadButton
        }
    }

    private var localOverflowMenu: some View {
        PaneMenuButton(systemName: "ellipsis", help: L("更多操作")) {
            Button(L("后退")) { model.goBack() }.disabled(!model.canGoBack)
            Button(L("前进")) { model.goForward() }.disabled(!model.canGoForward)
            Divider()
            localSortItems
            Divider()
            Toggle(L("显示隐藏文件"), isOn: $model.showHidden)
        }
    }

    @ViewBuilder
    private var localSortItems: some View {
        ForEach(FileSortField.allCases, id: \.self) { field in
            Button(field.displayName) { model.sort = FileSortOrder(field: field, ascending: model.sort.ascending) }
        }
        Divider()
        Toggle(L("升序"), isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 }))
    }

    private var localSortMenu: some View {
        PaneMenuButton(systemName: "arrow.up.arrow.down", help: L("排序")) {
            localSortItems
        }
    }

    private var uploadButton: some View {
        PaneIconButton(systemName: "arrow.up.circle",
                       help: model.selection.isEmpty
                       ? L("选择要上传的文件或文件夹")
                       : L("上传所选项目到 ") + uploadTarget.path,
                       isEnabled: !model.selection.isEmpty) {
            let entries = model.entries.filter { model.selection.contains($0.path) }
            app.upload(entries: entries, to: tab, destination: uploadTarget.path, pane: uploadTarget)
        }
    }


    private var pathBar: some View {
        PanePathField(placeholder: L("本地路径"), text: $pathText) {
            model.goTo(pathText)
            pathText = model.path
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.errorText {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(1)
            } else {
                Text(String(model.sortedEntries.count) + L(" 项")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if model.selection.isEmpty {
                Text(L("把远端文件拖到这里即下载"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary.opacity(0.8))
                    .lineLimit(1)
            } else {
                Text(L("已选 ") + String(model.selection.count) + L(" 项"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private func select(_ entry: FileEntry) {
        // Read the modifiers at click time: ⌘ toggles one row, ⇧ extends the
        // range from the anchor row, plain click replaces the selection.
        let flags = NSEvent.modifierFlags
        model.selectRow(entry.path,
                        in: model.sortedEntries,
                        command: flags.contains(.command),
                        shift: flags.contains(.shift))
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            model.open(entry)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
    }

    @ViewBuilder
    private func menu(for entry: FileEntry) -> some View {
        Button(entry.isDirectory ? L("打开文件夹") : L("在 Finder 中显示")) { open(entry) }
        Divider()
        Button(L("上传到 ") + uploadTarget.hostName) {
            app.upload(entries: [entry], to: tab, destination: uploadTarget.path, pane: uploadTarget)
        }
        Button(L("重命名")) {
            if let name = Prompt.text(title: L("重命名"), message: entry.name, defaultValue: entry.name) {
                app.renameLocal(entry, in: tab, to: name)
            }
        }
        Button(L("删除"), role: .destructive) {
            if Prompt.confirm(title: L("删除 ") + entry.name + "？", message: L("本地文件将被移到废纸篓。")) {
                app.deleteLocal([entry], in: tab)
            }
        }
        Divider()
        Button(L("新建文件夹")) {
            if let name = Prompt.text(title: L("新建文件夹"), message: L("名称")) {
                app.createLocalFolder(in: tab, name: name)
            }
        }
        Button(L("新建空文件")) {
            if let name = Prompt.text(title: L("新建空文件"), message: L("名称")) {
                app.createLocalFile(in: tab, name: name)
            }
        }
        Button(L("复制路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

}

// MARK: - Remote pane

struct RemoteBrowserPane: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: RemoteBrowserModel
    @ObservedObject var tab: TerminalTab
    /// True inside a narrow board pane, where the wide toolbar would be clipped.
    var isCompact: Bool = false
    @ViewState private var pathText = ""

    private var isMain: Bool { model === tab.remote }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            content
            Divider()
            footer
        }
        .background(Theme.panelBackground)
        // Before the connection is up model.path is still the placeholder ".",
        // and a stray dot in the address bar looked like a bug.
        .onAppear { pathText = model.isReady ? model.path : "" }
        .onChange(of: model.path) { path in
            if model.isReady { pathText = path }
        }
        .onChange(of: model.isReady) { ready in
            if ready { pathText = model.path }
        }
    }

    private var toolbar: some View {
        PaneHeader {
            Circle()
                .fill(model.isReady ? Theme.success : Theme.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .padding(.trailing, 3)
            HostPlatformIcon(platform: app.platform(for: model.hostID),
                             detail: app.platformInfo(for: model.hostID)?.detail,
                             size: 12)
            Text(model.hostName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.hostName)
            if model.isConnecting || model.isLoading {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 2)
            // Same adaptive rule as the local pane: several servers in one
            // window leave 200pt per pane, where the full control set would be
            // clipped at the right edge.
            ViewThatFits(in: .horizontal) {
                remoteWideControls
                remoteCompactControls
            }
        }
    }

    private var remoteWideControls: some View {
        HStack(spacing: 1) {
            PaneIconButton(systemName: "chevron.backward", help: L("后退"), isEnabled: model.canGoBack) {
                Task { await model.goBack() }
            }
            PaneIconButton(systemName: "chevron.forward", help: L("前进"), isEnabled: model.canGoForward) {
                Task { await model.goForward() }
            }
            PaneIconButton(systemName: "arrow.up", help: L("上级目录"), isEnabled: model.isReady) {
                Task { await model.goUp() }
            }
            // Deliberately enabled while disconnected: refreshing is how a pane
            // whose connection dropped gets re-dialled.
            PaneIconButton(systemName: "arrow.clockwise", help: L("刷新"), isEnabled: !model.isConnecting) {
                Task { await app.refreshSFTP(tab: tab, pane: model) }
            }
            historyMenu
            PaneDividerLine()
            remoteSortMenu
            PaneIconButton(systemName: model.showHidden ? "eye.fill" : "eye",
                           help: L("显示隐藏文件"),
                           isOn: model.showHidden) { model.showHidden.toggle() }
            PaneDividerLine()
            downloadButton
            addOrCloseButton
        }
    }

    private var remoteCompactControls: some View {
        HStack(spacing: 1) {
            PaneIconButton(systemName: "arrow.up", help: L("上级目录"), isEnabled: model.isReady) {
                Task { await model.goUp() }
            }
            // Refresh doubles as reconnect when the pane lost its connection.
            PaneIconButton(systemName: "arrow.clockwise", help: L("刷新"), isEnabled: !model.isConnecting) {
                Task { await app.refreshSFTP(tab: tab, pane: model) }
            }
            remoteOverflowMenu
            addOrCloseButton
        }
    }

    private var remoteOverflowMenu: some View {
        PaneMenuButton(systemName: "ellipsis", help: L("更多操作")) {
            Button(L("后退")) { Task { await model.goBack() } }.disabled(!model.canGoBack)
            Button(L("前进")) { Task { await model.goForward() } }.disabled(!model.canGoForward)
            Divider()
            historyItems
            Divider()
            remoteSortItems
            Divider()
            Toggle(L("显示隐藏文件"), isOn: $model.showHidden)
            Button(L("下载所选到本地")) {
                let entries = model.entries.filter { model.selection.contains($0.path) }
                app.download(entries: entries, from: tab, destination: tab.local.path, pane: model)
            }
            .disabled(model.selection.isEmpty)
        }
    }

    @ViewBuilder
    private var historyItems: some View {
        let history = model.hostID.map { app.sftpHistory(for: $0) } ?? []
        if history.isEmpty {
            Text(L("暂无历史文件夹"))
        } else {
            ForEach(history) { entry in
                Button(entry.path) { Task { await model.goTo(entry.path) } }
            }
            Divider()
            Button(L("清除历史")) {
                if let hostID = model.hostID { app.clearSFTPHistory(for: hostID) }
            }
        }
    }

    private var historyMenu: some View {
        PaneMenuButton(systemName: "clock.arrow.circlepath", help: L("最近访问过的文件夹")) {
            historyItems
        }
    }

    @ViewBuilder
    private var remoteSortItems: some View {
        ForEach(FileSortField.allCases, id: \.self) { field in
            Button(field.displayName) { model.sort = FileSortOrder(field: field, ascending: model.sort.ascending) }
        }
        Divider()
        Toggle(L("升序"), isOn: Binding(get: { model.sort.ascending }, set: { model.sort.ascending = $0 }))
    }

    private var remoteSortMenu: some View {
        PaneMenuButton(systemName: "arrow.up.arrow.down", help: L("排序")) {
            remoteSortItems
        }
    }

    private var downloadButton: some View {
        PaneIconButton(systemName: "arrow.down.circle",
                       help: model.selection.isEmpty
                       ? L("选择要下载的文件或文件夹")
                       : L("下载所选项目到本地当前目录"),
                       isEnabled: !model.selection.isEmpty) {
            let entries = model.entries.filter { model.selection.contains($0.path) }
            app.download(entries: entries, from: tab, destination: tab.local.path, pane: model)
        }
    }

    @ViewBuilder
    private var addOrCloseButton: some View {
        if isMain {
            PaneMenuButton(systemName: "plus.rectangle.on.rectangle", help: L("添加另一台服务器的 SFTP 面板")) {
                if app.hosts.isEmpty {
                    Text(L("还没有主机"))
                }
                ForEach(app.hosts) { host in
                    Button(host.name.isEmpty ? host.hostname : host.name) {
                        Task { await app.addSFTPPane(tab, host: host) }
                    }
                }
            }
        } else {
            PaneIconButton(systemName: "xmark", help: L("关闭该 SFTP 面板")) {
                app.closeSFTPPane(tab, pane: model)
            }
        }
    }


    private var pathBar: some View {
        PanePathField(placeholder: L("远端路径"), text: $pathText, isEnabled: model.isReady) {
            Task {
                await model.goTo(pathText)
                pathText = model.path
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.connectionError, !model.isReady {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                Text(L("无法打开 SFTP")).font(.system(size: 11, weight: .medium))
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Button(L("重试")) {
                    Task { await app.openSFTP(tab: tab, pane: model) }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isReady {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.isConnecting ? L("正在连接 ") + model.hostName + "…" : L("准备中…"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileListHeader(showsDetails: !isCompact)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if POSIXPath.normalize(model.path) != "/" {
                        ParentDirectoryRow { Task { await model.goUp() } }
                    }
                    ForEach(model.sortedEntries) { entry in
                        FileRowView(entry: entry, isSelected: model.selection.contains(entry.path), showsDetails: !isCompact)
                            .contentShape(Rectangle())
                            // Drag must be installed before the tap gestures,
                            // otherwise SwiftUI keeps the row in a tap sequence
                            // and no drag session ever begins.
                            .onDrag({
                                RemoteFileDrag.itemProvider(entries: dragEntries(grabbed: entry,
                                                                                 in: model.sortedEntries,
                                                                                 selected: model.selection),
                                                            grabbed: entry,
                                                            client: model.client,
                                                            hostID: model.hostID,
                                                            paneID: model.id)
                            }, preview: {
                                dragPreviewRow(for: entry,
                                               count: dragEntries(grabbed: entry,
                                                                  in: model.sortedEntries,
                                                                  selected: model.selection).count)
                            })
                            .onTapGesture(count: 2) { open(entry) }
                            .onTapGesture { select(entry) }
                            .contextMenu { menu(for: entry) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = model.errorText {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(1)
            } else {
                Text(String(model.sortedEntries.count) + L(" 项")).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if model.selection.isEmpty {
                Text(L("拖到其他面板即传输"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary.opacity(0.8))
                    .lineLimit(1)
            } else {
                Text(L("已选 ") + String(model.selection.count) + L(" 项"))
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private func select(_ entry: FileEntry) {
        // Read the modifiers at click time: ⌘ toggles one row, ⇧ extends the
        // range from the anchor row, plain click replaces the selection.
        let flags = NSEvent.modifierFlags
        model.selectRow(entry.path,
                        in: model.sortedEntries,
                        command: flags.contains(.command),
                        shift: flags.contains(.shift))
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            Task { await model.open(entry) }
        } else {
            app.openEditor(entry, in: tab, pane: model)
        }
    }

    @ViewBuilder
    private func menu(for entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button(L("打开")) { Task { await model.open(entry) } }
        } else {
            Button(L("编辑")) { app.openEditor(entry, in: tab, pane: model) }
        }
        Divider()
        Button(L("下载到本地当前目录")) {
            app.download(entries: [entry], from: tab, destination: tab.local.path, pane: model)
        }
        Divider()
        Button(L("重命名")) {
            if let name = Prompt.text(title: L("重命名远端文件"), message: entry.name, defaultValue: entry.name) {
                app.renameRemote(entry, in: tab, to: name, pane: model)
            }
        }
        Button(L("修改权限…")) {
            if let octal = Prompt.text(title: L("修改权限"), message: L("八进制，例如 755"), defaultValue: entry.displayOctal) {
                if let mode = UInt16(octal, radix: 8) {
                    app.setRemotePermissions(entry, in: tab, mode: mode, pane: model)
                }
            }
        }
        Button(L("删除"), role: .destructive) {
            if Prompt.confirm(title: L("删除 ") + entry.name + "？", message: L("远端文件将被永久删除。")) {
                app.deleteRemote([entry], in: tab, pane: model)
            }
        }
        Divider()
        Button(L("新建文件夹")) {
            if let name = Prompt.text(title: L("新建远端文件夹"), message: L("名称")) {
                app.createRemoteFolder(in: tab, name: name, pane: model)
            }
        }
        Button(L("新建空文件")) {
            if let name = Prompt.text(title: L("新建远端空文件"), message: L("名称")) {
                app.createRemoteFile(in: tab, name: name, pane: model)
            }
        }
        Button(L("复制路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
    }

}

// MARK: - Pane width

/// Reports the width a pane actually received. HSplitView children do not know
/// their own size, and the number of panes can change at any time, so each pane
/// measures itself instead of trusting a window-level breakpoint.
struct PaneWidthReader<Content: View>: View {
    var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size.width)
        }
    }
}

// MARK: - Transfer activity

/// Live progress for transfers belonging to this tab's hosts.
struct TransferActivityBar: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var tab: TerminalTab

    private var hostIDs: Set<UUID> {
        Set(tab.allRemotes.compactMap { $0.hostID })
    }

    private var active: [TransferProgress] {
        let hosts = hostIDs
        return app.transfers.filter { progress in
            guard let hostID = progress.hostID else { return false }
            return hosts.contains(hostID) && !progress.state.isTerminal
        }
    }

    var body: some View {
        if !active.isEmpty {
            VStack(spacing: 2) {
                ForEach(active.prefix(3)) { progress in
                    row(progress)
                }
                if active.count > 3 {
                    HStack {
                        Text(L("另有 ") + String(active.count - 3) + L(" 个传输…"))
                            .font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button(L("传输中心")) { app.showingTransferCenter = true }
                            .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 4)
            .background(Theme.panelBackground.opacity(0.95))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func row(_ progress: TransferProgress) -> some View {
        HStack(spacing: 6) {
            Image(systemName: progress.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text(progress.currentFile ?? URL(fileURLWithPath: progress.sourcePath).lastPathComponent)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 120)
            Text(String(Int((progress.fraction * 100).rounded())) + "%")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 32, alignment: .trailing)
            Text(FileAttributeFormatter.speed(bytesPerSecond: progress.bytesPerSecond))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 66, alignment: .trailing)
            Text(progress.state == .paused ? L("已暂停") : L("剩余 ") + (progress.remainingTime.map { FileAttributeFormatter.duration($0) } ?? "—"))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 78, alignment: .trailing)
            if progress.state == .running || progress.state == .queued {
                Button { app.pauseTransfer(progress) } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.plain)
            } else if progress.state == .paused {
                Button { app.resumeTransfer(progress) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.plain)
            }
            Button { app.cancelTransfer(progress) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Shared rows

/// Navigation stays outside the file collection so selecting or dragging a range
/// can never transfer the parent directory.
private struct ParentDirectoryRow: View {
    let goUp: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.left.up")
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .frame(width: 14)
            Text(verbatim: "..").font(.system(size: 11.5))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .background(hovering ? Theme.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: goUp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("上级目录"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("上级目录"), goUp)
        .help(L("上级目录"))
    }
}

struct FileListHeader: View {
    /// Narrow panes drop the size and date columns so names keep their room.
    var showsDetails: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            // Offsets "名称" past the 14pt icon + 6pt gap so the header sits
            // exactly above the file names instead of above the icons.
            Color.clear.frame(width: 14)
            Text(L("名称")).frame(maxWidth: .infinity, alignment: .leading)
            if showsDetails {
                Text(L("大小")).frame(width: 66, alignment: .trailing)
                Text(L("修改时间")).frame(width: 96, alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Theme.headerBackground.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator.opacity(0.45)).frame(height: 0.5)
        }
    }
}

struct FileRowView: View {
    let entry: FileEntry
    let isSelected: Bool
    var showsDetails: Bool = true

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14)
            Text(entry.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsDetails {
                Text(entry.displaySize)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 66, alignment: .trailing)
                Text(entry.displayDate)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 96, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Theme.accent : Color.clear)
                .frame(width: 2)
        }
        .onHover { hovering = $0 }
        .help(entry.displayPermissions + "  " + entry.displayOctal + "  " + entry.fullDate + "\n" + entry.path)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.rowSelection }
        return hovering ? Theme.rowHover : Color.clear
    }

    private var iconName: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return "arrow.turn.up.right"
        case .file: return "doc.text"
        case .other: return "questionmark.square"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory: return Theme.accent
        case .symlink: return Theme.warning
        default: return Theme.secondary
        }
    }
}
