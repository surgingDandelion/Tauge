import SwiftUI
import ShellXKit

/// Creates a workspace (board) in one step: name it, pick the layout, tick the
/// servers it should open. Termius calls this a "workspace"; here a board is an
/// independent set of panes, unrelated to the sidebar groups.
struct BoardCreateSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @ViewState private var name = ""
    @ViewState private var isGrid = true
    @ViewState private var connect = true
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
            result.append(("未分组", app.ungroupedHosts))
        }
        guard !query.isEmpty else { return result }
        let needle = query.lowercased()
        return result.compactMap { section in
            let hosts = section.hosts.filter {
                app.matchesSearch($0, query: needle) || section.title.lowercased().contains(needle)
            }
            return hosts.isEmpty ? nil : (section.title, hosts)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            serverPicker
            Divider()
            footer
        }
        .frame(width: 560, height: 580)
        .background(Theme.windowBackground)
        .onAppear {
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                name = "工作区 \(app.boards.count + 1)"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x3").foregroundStyle(Theme.accent)
            Text("新建工作区").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var form: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("名称").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(width: 52, alignment: .leading)
                TextField("工作区名称", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Text("布局").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(width: 52, alignment: .leading)
                Picker("", selection: $isGrid) {
                    Text("宫格（每个服务器一个窗格）").tag(true)
                    Text("单窗格（列表里切换）").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 8) {
                Text("").frame(width: 52)
                Toggle("创建后立即连接", isOn: $connect)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var serverPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                TextField("搜索主机", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Spacer()
                Text("已选 \(selection.count) 台")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Button("全选") {
                    selection = Set(sections.flatMap { $0.hosts.map(\.id) })
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Button("清空") { selection.removeAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            Divider()
            if sections.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有主机").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Text("先在侧边栏新建主机，或者从 ~/.ssh/config 导入。")
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
            Button(selection.isSuperset(of: ids) ? "取消该组" : "选择该组") {
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
            }
            .padding(.horizontal, 16)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(selection.isEmpty ? "不选服务器也可以，创建后再添加" : "将打开 \(selection.count) 个窗格")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("创建") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func create() {
        let ordered = sections.flatMap { $0.hosts }.map(\.id).filter { selection.contains($0) }
        app.createBoardFromSheet(name: name,
                                 hostIDs: ordered,
                                 isGrid: isGrid,
                                 connect: connect)
        dismiss()
    }
}
