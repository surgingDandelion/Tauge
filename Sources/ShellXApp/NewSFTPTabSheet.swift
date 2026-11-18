import SwiftUI
import ShellXKit

/// Host chooser for "新建 SFTP 标签": the tab gets one local pane plus one
/// remote pane per ticked server, so files can be moved between servers.
struct NewSFTPTabSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @ViewState private var selection: Set<UUID> = []
    @ViewState private var query = ""

    private var sections: [(title: String, hosts: [SSHHost])] {
        var result: [(title: String, hosts: [SSHHost])] = []
        func walk(_ nodes: [SidebarGroupNode]) {
            for node in nodes {
                if !node.hosts.isEmpty {
                    result.append((app.groupPath(for: node.group.id), node.hosts))
                }
                walk(node.children)
            }
        }
        walk(app.sidebarTree)
        if !app.ungroupedHosts.isEmpty {
            result.append((L("未分组"), app.ungroupedHosts))
        }
        guard !query.isEmpty else { return result }
        return result.compactMap { section in
            let hosts = section.hosts.filter { app.matchesSearch($0, query: query) }
            return hosts.isEmpty ? nil : (section.title, hosts)
        }
    }

    private var orderedSelection: [SSHHost] {
        app.hosts.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picker
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .background(Theme.windowBackground)
        .onAppear {
            guard selection.isEmpty else { return }
            // Start on whatever the user is looking at: the sidebar selection,
            // otherwise the host of the current tab.
            let candidates = [app.selectedSidebarHostID, app.selectedTab?.hostID]
            if let id = candidates.compactMap({ $0 }).first(where: { app.host(id: $0) != nil }) {
                selection = [id]
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("新建 SFTP 标签")).font(.system(size: 13, weight: .semibold))
                Text(L("勾选服务器，每台一个远端面板；面板之间可以直接拖拽传输"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                TextField(L("搜索主机"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Text(L("已选 %d 台", selection.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Button(L("全选")) {
                    selection = Set(sections.flatMap { $0.hosts.map(\.id) })
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Button(L("清空")) { selection.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            Divider()
            if sections.isEmpty {
                VStack(spacing: 6) {
                    Text(L("还没有主机")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text(L("先在起始页新建主机，或者从 ~/.ssh/config 导入。"))
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.title) { section in
                            sectionHeader(section)
                            ForEach(section.hosts) { host in
                                row(for: host)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func sectionHeader(_ section: (title: String, hosts: [SSHHost])) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer()
            let ids = Set(section.hosts.map(\.id))
            Button(selection.isSuperset(of: ids) ? L("取消该组") : L("选择该组")) {
                if selection.isSuperset(of: ids) { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func row(for host: SSHHost) -> some View {
        let checked = selection.contains(host.id)
        return Button {
            if checked { selection.remove(host.id) } else { selection.insert(host.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(checked ? Theme.accent : Theme.secondary)
                Text(host.name.isEmpty ? host.hostname : host.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(host.displayAddress)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer()
                if case .hosts(let ids) = host.jumpPolicy, !ids.isEmpty {
                    Text(L("跳板"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? L("至少选择一台服务器") : L("将打开 1 个本地面板与 %d 个远端面板", selection.count))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L("打开")) { open() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func open() {
        let hosts = orderedSelection
        guard let first = hosts.first else { return }
        let rest = hosts.dropFirst().map(\.id)
        app.openSFTPTab(for: first, extraHostIDs: rest)
        dismiss()
    }
}
