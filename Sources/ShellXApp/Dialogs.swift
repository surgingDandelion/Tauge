import SwiftUI
import AppKit
import ShellXKit

struct PasswordPromptView: View {
    @EnvironmentObject private var app: AppState
    let prompt: PasswordPrompt
    @ViewState private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title).font(.system(size: 14, weight: .semibold))
            Text(prompt.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Group {
                if prompt.isPassphrase {
                    SecureField(L("口令"), text: $value)
                } else {
                    SecureField(L("密码"), text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { submit() }
            HStack {
                Spacer()
                Button(L("取消")) { app.cancelPasswordPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button(L("确定")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            value = prompt.initialValue
            focused = true
        }
    }

    private func submit() {
        guard !value.isEmpty else { return }
        app.submitPassword(value)
    }
}

struct HostKeyPromptView: View {
    @EnvironmentObject private var app: AppState
    let prompt: HostKeyPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: prompt.isChanged ? "exclamationmark.triangle.fill" : "lock.shield")
                    .foregroundStyle(prompt.isChanged ? Theme.danger : Theme.accent)
                Text(prompt.isChanged ? L("主机密钥已变更") : L("未知主机密钥"))
                    .font(.system(size: 14, weight: .semibold))
            }

            if prompt.isChanged {
                Text(L("该主机的密钥与 known_hosts 中记录不一致，可能存在中间人攻击。除非你确认主机被重装过，否则请取消连接。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("这是首次连接该主机，请核对指纹后再信任。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                keyValue(L("主机"), prompt.info.host + ":" + String(prompt.info.port))
                keyValue(L("算法"), prompt.info.keyType)
                if let previous = prompt.previousFingerprint {
                    HStack(alignment: .top, spacing: 6) {
                        Text(L("旧指纹")).font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 54, alignment: .leading)
                        Text(previous).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(prompt.isChanged ? L("新指纹") : "SHA256")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        .frame(width: 54, alignment: .leading)
                    Text(prompt.info.fingerprintSHA256)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(prompt.isChanged ? Theme.danger : Color.primary)
                        .textSelection(.enabled)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text("MD5").font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 54, alignment: .leading)
                    Text(prompt.info.fingerprintMD5)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(Theme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button(L("拒绝")) { app.resolveHostKeyPrompt(.reject) }
                    .keyboardShortcut(.cancelAction)
                if !prompt.isChanged {
                    Button(L("仅本次信任")) { app.resolveHostKeyPrompt(.trust(remember: false)) }
                }
                Button(prompt.isChanged ? L("确认变更并信任") : L("信任并保存")) {
                    app.resolveHostKeyPrompt(.trust(remember: true))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func keyValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 54, alignment: .leading)
            Text(value).font(.system(size: 11)).textSelection(.enabled)
        }
    }
}

struct ConflictPromptView: View {
    @EnvironmentObject private var app: AppState
    let conflict: PendingConflict
    @ViewState private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(conflict.title).font(.system(size: 14, weight: .semibold))
            Text(conflict.message).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Toggle(L("应用于全部冲突"), isOn: $applyToAll)
                .font(.system(size: 11))
            HStack(spacing: 8) {
                ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                    Button(policy.displayName) {
                        app.resolveConflict(policy, applyToAll: applyToAll)
                    }
                }
                Spacer()
                Button(L("取消")) { app.resolveConflict(nil, applyToAll: false) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

struct EditorView: View {
    @EnvironmentObject private var app: AppState
    let context: EditorContext

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
                Text(context.path).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button(L("保存")) { app.saveEditor() }
                Button(L("关闭")) { app.editor = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            TextEditor(text: Binding(
                get: { app.editor?.text ?? context.text },
                set: { newValue in
                    app.editor?.text = newValue
                    app.editor?.isDirty = true
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .padding(4)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var query = ""
    @ViewState private var selection = 0
    @ViewState private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private var items: [CommandPaletteItem] {
        let all = app.commandPaletteItems
        guard !query.isEmpty else { return all }
        let lowered = query.lowercased()
        return all.filter { item in
            if item.title.lowercased().contains(lowered) || item.subtitle.lowercased().contains(lowered) {
                return true
            }
            if let host = item.host { return app.matchesSearch(host, query: query) }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField(L("搜索主机或命令"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { activateCurrent() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(sections) { section in
                            if let title = section.title {
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
                                paletteRow(item: entry.item, index: entry.index)
                                    .id(entry.item.id)
                            }
                        }
                    }
                }
                .onChange(of: selection) { newValue in
                    if items.indices.contains(newValue) {
                        proxy.scrollTo(items[newValue].id, anchor: .center)
                    }
                }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .onAppear {
            focused = true
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: query) { _ in selection = 0 }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:
                moveSelection(1)
                return nil
            case 126:
                moveSelection(-1)
                return nil
            case 53:
                app.showingCommandPalette = false
                return nil
            default:
                return event
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
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

    /// Hosts keep the sidebar's tree order, so the palette inserts a section
    /// header per group and indents rows by depth; commands and workspaces get
    /// their own sections the same way.
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

    private func paletteRow(item: CommandPaletteItem, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind == .host ? (item.id.hasPrefix("sftp-") ? "folder" : "terminal") : "command")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12))
                Text(item.subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(.leading, 12 + CGFloat(item.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 34)
        .background(index == selection ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = index
            activateCurrent()
        }
    }

    private func activateCurrent() {
        guard items.indices.contains(selection) else {
            if let first = items.first { app.activateCommand(first) }
            return
        }
        app.activateCommand(items[selection])
    }
}

struct KeyImporterView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var path = ""
    @ViewState private var name = ""
    @ViewState private var passphrase = ""
    @ViewState private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("导入私钥")).font(.system(size: 14, weight: .semibold))
            Text(L("支持 OpenSSH 新格式、PKCS#1、PKCS#8 与 SEC1；密钥类型含 Ed25519、ECDSA 与 RSA（rsa-sha2-256/512）。")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack {
                TextField(L("私钥路径"), text: $path).textFieldStyle(.roundedBorder)
                Button(L("选择…")) { chooseFile() }
            }
            TextField(L("显示名称"), text: $name).textFieldStyle(.roundedBorder)
            SecureField(L("口令（如私钥有加密）"), text: $passphrase).textFieldStyle(.roundedBorder)
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(Theme.danger)
            }
            HStack {
                Spacer()
                Button(L("取消")) { app.showingKeyImporter = false }
                    .keyboardShortcut(.cancelAction)
                Button(L("导入")) { importKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }

    private func importKey() {
        do {
            let parsed = try SSHKeyParser.parse(path: (path as NSString).expandingTildeInPath,
                                                passphrase: passphrase.isEmpty ? nil : passphrase)
            let expanded = (path as NSString).expandingTildeInPath
            let record = PrivateKeyRecord(name: name.isEmpty ? (expanded as NSString).lastPathComponent : name,
                                          publicKeyOpenSSH: parsed.publicKeyOpenSSH,
                                          fingerprintSHA256: fingerprint(of: parsed.publicKeyOpenSSH),
                                          hasPassphrase: !passphrase.isEmpty,
                                          storageRef: "file:" + expanded)
            app.savePrivateKey(record)
            app.showingKeyImporter = false
            app.presentMessage(L("私钥已导入"), record.name + "  " + record.fingerprintSHA256)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func fingerprint(of openSSH: String) -> String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1])) else { return "" }
        return KeyFingerprint.sha256(data)
    }
}
