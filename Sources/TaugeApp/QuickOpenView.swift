import SwiftUI
import TaugeKit

/// Spotlight-style quick open (⌘K): type, the first row is the machine or
/// workspace you meant, return connects.
///
/// It used to be a `sheet`, which arrives as a window-modal card and drags the
/// whole window with it. A quick-open should feel like an overlay you can
/// dismiss by clicking away, so the panel is drawn inside the window and only
/// swallows keys while it is up.
struct QuickOpenView: View {
    private static let resultsViewportHeight: CGFloat = 380

    @EnvironmentObject private var app: AppState
    @ViewState private var query = ""
    @ViewState private var selection = 0
    @ViewState private var selectedIndices: Set<Int> = []
    @ViewState private var selectionAnchor: Int? = nil
    @ViewState private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private var items: [CommandPaletteItem] { app.commandPaletteResults(query: query) }

    /// While a query is typed the list is a ranking, not the sidebar tree, so
    /// group headers would only interrupt the order the user is reading.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            panel
                .padding(.top, 84)
        }
        .onAppear {
            resetSelection()
            activate()
        }
        .onDisappear { removeMonitor() }
        .onChange(of: query) { _ in resetSelection() }
        // TextField owns the first responder, so arrow keys can be consumed by
        // AppKit before the local monitor sees them. SwiftUI's move command is
        // delivered at the view level and keeps ↑/↓ moving the highlighted row.
        .onMoveCommand { direction in
            switch direction {
            case .up: move(-1)
            case .down: move(1)
            default: break
            }
        }
        // Typing narrows the list under the highlight; keep it on a real row
        // instead of pointing past the end after the results shrink.
        .onChange(of: items.count) { count in
            normalizeSelection(count: count)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                TextField(L("搜索主机、工作区或命令"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Divider()

            if items.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            hints
        }
        .frame(width: 620)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
        .shadow(color: Theme.shadow, radius: 24, y: 10)
    }

    private var listHeight: CGFloat {
        // Keep the viewport stable while the query changes. A dynamic height
        // makes the entire overlay jump on every keystroke and moves the row
        // under the pointer, which makes both scrolling and clicking unreliable.
        Self.resultsViewportHeight
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sections) { section in
                        if let title = section.title, !isSearching {
                            Text(title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(section.entries) { entry in
                            row(item: entry.item, index: entry.index)
                                .id(entry.item.id)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: listHeight)
            .onChange(of: selection) { newValue in
                guard items.indices.contains(newValue) else { return }
                proxy.scrollTo(items[newValue].id, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(L("没有匹配的主机、工作区或命令"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Text(L("试着输入名称、地址、分组或标签的一部分"))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .frame(height: listHeight)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint("↑↓", L("选择"))
            hint("⇧", L("连选"))
            hint("⌃", L("多选"))
            if selectedHostCount > 1 {
                hint("↩", L("新工作区"))
                hint("⌘↩", L("SFTP 宫格"))
            } else {
                hint("↩", L("打开并连接"))
                hint("⌘↩", L("新 SFTP 标签"))
            }
            hint("esc", L("关闭"))
            Spacer()
            Text(selectedHostCount > 0
                 ? L("已选 %d 台", selectedHostCount)
                 : L("%d 项", items.count))
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Theme.headerBackground.opacity(0.6))
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBackground))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.separator, lineWidth: 0.5))
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
        }
    }

    private struct PaletteEntry: Identifiable {
        let id: String
        let item: CommandPaletteItem
        let index: Int
    }

    private struct PaletteSection: Identifiable {
        let id: String
        let title: String?
        var entries: [PaletteEntry]
    }

    /// Hosts keep the sidebar's tree order, so a section header appears per
    /// group and rows are indented by depth; commands and workspaces get their
    /// own sections the same way.
    private var sections: [PaletteSection] {
        var result: [PaletteSection] = []
        for (index, item) in items.enumerated() {
            let entry = PaletteEntry(id: item.id, item: item, index: index)
            if var last = result.last, last.title == item.groupTitle {
                last.entries.append(entry)
                result[result.count - 1] = last
            } else {
                let id = (item.groupTitle ?? "section") + "-" + String(index)
                result.append(PaletteSection(id: id, title: item.groupTitle, entries: [entry]))
            }
        }
        return result
    }

    private func symbol(for item: CommandPaletteItem) -> String {
        if item.id.hasPrefix("board-") { return "square.grid.2x2" }
        return item.kind == .host ? "terminal" : "command"
    }

    private func row(item: CommandPaletteItem, index: Int) -> some View {
        Button {
            selectRow(index)
        } label: {
            HStack(spacing: 8) {
                leadingIcon(for: item, isSelected: selectedIndices.contains(index))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 12)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if index == selection {
                    Text("↩")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.leading, 12 + CGFloat(item.depth) * 14)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .background(selectedIndices.contains(index) ? Theme.rowSelection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
    }

    @ViewBuilder
    private func leadingIcon(for item: CommandPaletteItem, isSelected: Bool) -> some View {
        if let host = item.host, item.kind == .host {
            HStack(spacing: 4) {
                if let color = app.resolvedColorHex(for: host).flatMap({ Color(hex: $0) }) {
                    Circle()
                        .fill(color.opacity(isSelected ? 1 : 0.8))
                        .frame(width: 5, height: 5)
                }
                HostPlatformIcon(platform: app.platform(for: host.id),
                                 detail: app.platformInfo(for: host.id)?.detail,
                                 size: 14,
                                 fallbackColor: isSelected ? Theme.accent : Theme.secondary)
            }
            .frame(width: 20, height: 16, alignment: .leading)
        } else {
            Image(systemName: symbol(for: item))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
                .frame(width: 16)
        }
    }

    // MARK: - Keyboard

    /// Focus is taken from the terminal explicitly: the overlay appears while an
    /// SSH view owns the keyboard, and SwiftUI will not hand the field focus
    /// while another responder still holds it.
    private func activate() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        focused = true
        installMonitor()
        // The window may still be finishing its own focus pass for one runloop
        // turn; retry once instead of leaving the field deaf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !focused { focused = true }
        }
    }

    private func installMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125: // ↓
                move(1, modifiers: event.modifierFlags)
                return nil
            case 126: // ↑
                move(-1, modifiers: event.modifierFlags)
                return nil
            case 53: // esc
                dismiss()
                return nil
            case 36, 76: // return, keypad enter
                activateCurrent(prefersSFTP: event.modifierFlags.contains(.command))
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func move(_ delta: Int) {
        move(delta, modifiers: [])
    }

    private func move(_ delta: Int, modifiers: NSEvent.ModifierFlags) {
        let next = QuickOpen.movedSelection(from: selection, by: delta, count: items.count)
        if modifiers.contains(.shift) {
            extendSelection(to: next)
        } else if modifiers.contains(.control) || modifiers.contains(.command) {
            toggleSelection(at: next)
        } else {
            selectSingle(index: next)
        }
    }

    private func selectRow(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            extendSelection(to: index)
        } else if modifiers.contains(.control) || modifiers.contains(.command) {
            toggleSelection(at: index)
        } else {
            selectSingle(index: index)
        }
    }

    private func resetSelection() {
        selection = 0
        selectedIndices = items.isEmpty ? [] : [0]
        selectionAnchor = nil
    }

    private func normalizeSelection(count: Int) {
        guard count > 0 else {
            selection = 0
            selectedIndices = []
            selectionAnchor = nil
            return
        }
        selection = QuickOpen.movedSelection(from: selection, by: 0, count: count)
        selectedIndices = Set(selectedIndices.filter { $0 >= 0 && $0 < count })
        if selectedIndices.isEmpty { selectedIndices = [selection] }
        if let anchor = selectionAnchor {
            selectionAnchor = QuickOpen.movedSelection(from: anchor, by: 0, count: count)
        }
    }

    private func selectSingle(index: Int) {
        guard items.indices.contains(index) else { return }
        selection = index
        selectedIndices = [index]
        selectionAnchor = nil
    }

    private func extendSelection(to index: Int) {
        guard items.indices.contains(index) else { return }
        let anchor = selectionAnchor ?? selection
        selectionAnchor = anchor
        selection = index
        selectedIndices = QuickOpen.selectionRange(anchor: anchor,
                                                   current: index,
                                                   count: items.count)
    }

    private func toggleSelection(at index: Int) {
        guard items.indices.contains(index) else { return }
        guard items[index].host != nil else {
            selectSingle(index: index)
            return
        }
        selection = index
        selectionAnchor = index
        if selectedIndices.contains(index), selectedIndices.count > 1 {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
        if selectedIndices.isEmpty { selectedIndices = [index] }
    }

    private var selectedHostCount: Int {
        var ids = Set<UUID>()
        for index in selectedIndices where items.indices.contains(index) {
            if let host = items[index].host { ids.insert(host.id) }
        }
        return ids.count
    }

    private var selectedHosts: [SSHHost] {
        var seen = Set<UUID>()
        return selectedIndices.sorted().compactMap { index in
            guard items.indices.contains(index), let host = items[index].host,
                  seen.insert(host.id).inserted else { return nil }
            return host
        }
    }

    private func activateCurrent(prefersSFTP: Bool) {
        let hosts = selectedHosts
        if hosts.count > 1 {
            app.openTemporaryBoard(for: hosts, showsSFTP: prefersSFTP)
            dismiss()
            return
        }
        guard items.indices.contains(selection) else {
            if let first = items.first { app.activateCommand(first, prefersSFTP: prefersSFTP) }
            dismiss()
            return
        }
        app.activateCommand(items[selection], prefersSFTP: prefersSFTP)
        dismiss()
    }

    private func dismiss() {
        removeMonitor()
        app.showingCommandPalette = false
        // Closing the overlay leaves no sheet to restore the keyboard, so the
        // terminal gets it back explicitly.
        app.scheduleTerminalFocus(0.05)
    }
}
