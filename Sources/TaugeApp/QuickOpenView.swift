import SwiftUI
import TaugeKit

/// The quick-open overlay connects directly from the current result and owns
/// keyboard events only while it is visible.
struct QuickOpenView: View {
    private static let resultsViewportHeight: CGFloat = 280

    @EnvironmentObject private var app: AppState
    @ViewState private var query = ""
    @ViewState private var scope: Scope = .all
    @ViewState private var selection = ResultSelection()
    @ViewState private var focusRequest = 0

    private enum Scope: CaseIterable, Hashable {
        case all, hosts, workspaces, commands

        var title: String {
            switch self {
            case .all: return L("全部")
            case .hosts: return L("主机")
            case .workspaces: return L("工作区")
            case .commands: return L("命令")
            }
        }

        static func category(for item: CommandPaletteItem) -> Self {
            if item.host != nil { return .hosts }
            return item.id.hasPrefix("board-") ? .workspaces : .commands
        }
    }

    private var items: [CommandPaletteItem] {
        app.commandPaletteResults(query: query).filter { scope == .all || Scope.category(for: $0) == scope }
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let results = items
        let visible = selection.visible(in: results.map(\.id))
        GeometryReader { geometry in
            let inset = min(64, geometry.size.height * 0.11)
            let listHeight = min(Self.resultsViewportHeight, max(0, geometry.size.height - inset - 133))
            ZStack(alignment: .top) {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }

                panel(results: results, selection: visible, listHeight: listHeight)
                    .frame(width: min(520, max(0, geometry.size.width - 28)))
                    .padding(.top, inset)
            }
        }
    }

    private func panel(results: [CommandPaletteItem], selection: ResultSelection, listHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            fieldBar
            hairline
            scopeBar

            Group {
                if results.isEmpty {
                    emptyState
                } else {
                    list(results: results, selection: selection)
                }
            }
            // Editing a query should not move a result under the pointer.
            .frame(height: listHeight)

            hairline
            footer(selectedHostCount: selectedHosts(in: results, selection: selection).count)
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.17), radius: 22, y: 12)
        .shadow(color: Theme.shadow, radius: 3, y: 2)
    }

    private var fieldBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            QuickOpenSearchField(query: query, onChange: setQuery, onKeyDown: handleKey,
                                 focusRequest: focusRequest)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
            if !query.isEmpty {
                Button {
                    setQuery("")
                    focusRequest += 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("清空搜索"))
                .accessibilityLabel(L("清空搜索"))
            }
            Button(action: dismiss) {
                Text("esc")
                    .font(TechFont.mono(10, .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 33, height: 25)
                    .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.cardStroke, lineWidth: 0.8)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("关闭"))
            .accessibilityLabel(L("关闭"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 13)
        .frame(height: 53)
        .background(Theme.panelBackground)
    }

    private var scopeBar: some View {
        HStack(spacing: 3) {
            ForEach(Scope.allCases, id: \.self) { candidate in
                Button {
                    if scope != candidate {
                        scope = candidate
                        selection = ResultSelection()
                    }
                    focusRequest += 1
                } label: {
                    Text(candidate.title)
                        .font(.system(size: 11.5, weight: scope == candidate ? .semibold : .regular))
                        .foregroundStyle(scope == candidate ? Color.primary : Theme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .modifier(QuickOpenHoverHighlight(selected: scope == candidate))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scope == candidate ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private func list(results: [CommandPaletteItem], selection: ResultSelection) -> some View {
        let rows = resultRows(for: results, selection: selection)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = result.sectionTitle {
                                SearchSectionTitle(title: title)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 5)
                                    .padding(.bottom, 1)
                            }
                            row(item: result.item, isSelected: result.isSelected, isFocused: result.isFocused)
                        }
                        .id(result.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            .onChange(of: selection.focusedID) { id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: query) { _ in
                if let id = selection.focusedID { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private struct ResultRow: Identifiable {
        let item: CommandPaletteItem
        let sectionTitle: String?
        let isSelected: Bool
        let isFocused: Bool

        var id: String { item.id }
    }

    private func resultRows(for results: [CommandPaletteItem], selection: ResultSelection) -> [ResultRow] {
        // Keep each row in the same lazy stack when filtering removes the headers.
        let showsHeaders = !isSearching || scope != .all
        var previousCategory: Scope?
        return results.map { item in
            let category = Scope.category(for: item)
            let title = showsHeaders && category != previousCategory ? category.title : nil
            previousCategory = category
            return ResultRow(item: item, sectionTitle: title, isSelected: selection.ids.contains(item.id),
                             isFocused: selection.focusedID == item.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .light))
                .accessibilityHidden(true)
            Text(L("没有匹配的主机、工作区或命令"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
            Text(L("试着输入名称、地址、分组或标签的一部分"))
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(selectedHostCount: Int) -> some View {
        let isMultiple = selectedHostCount > 1
        return HStack(spacing: 12) {
            SearchShortcutHint(keys: "↑↓", title: L("选择"))
            SearchShortcutHint(keys: "↩", title: isMultiple ? L("新工作区") : L("打开"))
            SearchShortcutHint(keys: "⌘↩", title: isMultiple ? L("SFTP 宫格") : "SFTP")
            Spacer(minLength: 0)
            if isMultiple {
                Text(L("已选 %d 台", selectedHostCount)).lineLimit(1)
            }
            Button {
                app.showCatalogSearch(initialQuery: query)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 23, height: 24)
                    .modifier(QuickOpenHoverHighlight(selected: false))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("打开完整搜索"))
            .accessibilityLabel(L("打开完整搜索"))
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Theme.tabRailBackground)
    }

    private func row(item: CommandPaletteItem, isSelected: Bool, isFocused: Bool) -> some View {
        let subtitle = rowSubtitle(for: item)
        return Button {
            clickRow(item.id, modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
        } label: {
            HStack(spacing: 8) {
                SearchResultMark(item: item, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }
                .help(subtitle.isEmpty ? item.title : item.title + "\n" + subtitle)
                Spacer(minLength: 5)
                if isFocused {
                    SearchKeycap(keys: "↩")
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .modifier(QuickOpenHoverHighlight(selected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(item.id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowSubtitle(for item: CommandPaletteItem) -> String {
        guard item.host != nil, let path = item.groupTitle, !path.isEmpty else { return item.subtitle }
        return item.subtitle.isEmpty ? path : item.subtitle + " · " + path
    }

    // MARK: - Interaction

    /// Store stable row IDs: a catalog refresh or a new ranking must not turn
    /// a highlighted index into a different target for Return.
    private struct ResultSelection {
        var focusedID: String?
        var ids: Set<String> = []
        var anchorID: String?

        func visible(in order: [String]) -> Self {
            let available = Set(order)
            var result = self
            result.ids.formIntersection(available)
            if let anchorID, !available.contains(anchorID) { result.anchorID = nil }
            if let focusedID, result.ids.contains(focusedID) { return result }
            result.focusedID = order.first(where: result.ids.contains) ?? order.first
            if let id = result.focusedID, result.ids.isEmpty { result.ids.insert(id) }
            return result
        }
    }

    private func setQuery(_ text: String) {
        guard query != text else { return }
        // Reset synchronously with the edit, not in a later onChange callback.
        selection = ResultSelection()
        query = text
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard app.showingCommandPalette, !app.hasPresentedSheet, app.alert == nil else { return false }
        switch event.keyCode {
        case 125: move(1, modifiers: event.modifierFlags)
        case 126: move(-1, modifiers: event.modifierFlags)
        case 53: dismiss()
        case 36, 76: activateCurrent(prefersSFTP: event.modifierFlags.contains(.command))
        default: return false
        }
        return true
    }

    private func move(_ delta: Int, modifiers: NSEvent.ModifierFlags) {
        let results = items
        let order = results.map(\.id)
        guard let id = selection.visible(in: order).focusedID, let index = order.firstIndex(of: id) else { return }
        let next = QuickOpen.movedSelection(from: index, by: delta, count: order.count)
        guard next != index else { return }
        select(results[next], in: order, modifiers: modifiers)
    }

    private func clickRow(_ id: String, modifiers: NSEvent.ModifierFlags) {
        guard app.showingCommandPalette, !app.hasPresentedSheet, app.alert == nil else { return }
        let results = items
        guard let item = results.first(where: { $0.id == id }) else { return }
        if !modifiers.intersection([.shift, .control, .command]).isEmpty {
            select(item, in: results.map(\.id), modifiers: modifiers)
        } else {
            // A plain click activates the actual clicked row, regardless of
            // the keyboard highlight or any earlier multi-selection.
            activate(item, prefersSFTP: false)
        }
    }

    private func select(_ item: CommandPaletteItem, in order: [String], modifiers: NSEvent.ModifierFlags) {
        var next = selection.visible(in: order)
        if modifiers.contains(.shift),
           let anchorID = next.anchorID ?? next.focusedID,
           let anchor = order.firstIndex(of: anchorID), let index = order.firstIndex(of: item.id) {
            let range = min(anchor, index)...max(anchor, index)
            next = ResultSelection(focusedID: item.id, ids: Set(order[range]), anchorID: anchorID)
        } else if item.host != nil, !modifiers.intersection([.control, .command]).isEmpty {
            next.focusedID = item.id
            next.anchorID = item.id
            if next.ids.contains(item.id), next.ids.count > 1 {
                next.ids.remove(item.id)
            } else {
                next.ids.insert(item.id)
            }
        } else {
            next = ResultSelection(focusedID: item.id, ids: [item.id])
        }
        selection = next.visible(in: order)
    }

    private func selectedHosts(in results: [CommandPaletteItem], selection: ResultSelection) -> [SSHHost] {
        var seen = Set<UUID>()
        return results.compactMap { item in
            guard selection.ids.contains(item.id), let host = item.host,
                  seen.insert(host.id).inserted else { return nil }
            return host
        }
    }

    private func activateCurrent(prefersSFTP: Bool) {
        let results = items
        let visible = selection.visible(in: results.map(\.id))
        let hosts = selectedHosts(in: results, selection: visible)
        if hosts.count > 1 {
            dismiss()
            app.openTemporaryBoard(for: hosts, showsSFTP: prefersSFTP)
        } else if let item = results.first(where: { $0.id == visible.focusedID }) {
            activate(item, prefersSFTP: prefersSFTP)
        }
    }

    private func activate(_ item: CommandPaletteItem, prefersSFTP: Bool) {
        app.activateCommand(item, prefersSFTP: prefersSFTP)
        app.scheduleTerminalFocus(0.05)
    }

    private func dismiss() {
        app.showingCommandPalette = false
        app.scheduleTerminalFocus(0.05)
    }
}

private struct QuickOpenHoverHighlight: ViewModifier {
    private static let selectionFill = Theme.dynamic(light: 0xE8EDF4, dark: 0x333940)

    let selected: Bool
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Self.selectionFill : hovering ? Theme.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
    }
}
