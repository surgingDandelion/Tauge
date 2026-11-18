import SwiftUI
import ShellXKit

/// "一键导入 Termius 配置": decrypts the local Termius vault and previews what
/// would be created before writing anything into the catalog.
struct TermiusImportView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @ViewState private var keyText = ""
    @ViewState private var showAdvanced = false

    private var session: TermiusImportSession? { app.termiusImport }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                if session.isLoading {
                    loading
                } else if session.errorText != nil, session.catalogue.decryptedCount == 0 {
                    failure(session)
                } else {
                    content(session)
                }
            } else {
                loading
            }
            Divider()
            footer
        }
        .frame(width: 580, height: 620)
        .background(Theme.windowBackground)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("从 Termius 导入"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("读取本机 Termius 的主机、身份、密钥与 known_hosts，不会修改 Termius 的数据"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if let session, !session.isLoading, !session.sourcePath.isEmpty {
                Text(session.sourcePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190)
                    .help(session.sourcePath)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("正在读取并解密 Termius 本地数据库…"))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            if session?.slowHint == true {
                Text(L("还在等待钥匙串授权。若系统弹出了“Tauge 想访问钥匙串中的 Termius”，请点“始终允许”。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ session: TermiusImportSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("没读到 Termius 的配置"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(session.errorText ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Termius 的数据库用登录钥匙串里的密钥加密。正常情况下点重试即可；系统提示时请允许 Tauge 访问。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                Text(L("也可以在终端执行 security find-generic-password -s Termius -a localKey -w 取出密钥，粘贴到这里："))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 8) {
                    TextField(L("44 个 base64 字符的密钥"), text: $keyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button(L("用此密钥读取")) {
                        Task { await app.loadTermiusCatalogue(keyText: keyText) }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    private func content(_ session: TermiusImportSession) -> some View {
        VStack(spacing: 0) {
            stats(session)
            Divider()
            options(session)
            Divider()
            hostList(session)
        }
    }

    private func stats(_ session: TermiusImportSession) -> some View {
        HStack(spacing: 8) {
            statChip(L("主机"), session.catalogue.savedHosts.count)
            statChip(L("身份"), session.catalogue.identities.count)
            statChip(L("私钥"), session.catalogue.keys.count)
            statChip("known_hosts", session.catalogue.knownHosts.count)
            statChip(L("连接记录"), session.catalogue.history.count)
            Spacer()
            Text(L("解密 ") + String(session.catalogue.decryptedCount) + L(" 条记录"))
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private func statChip(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            Text(String(value))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.panelBackground.opacity(0.7))
        .clipShape(Capsule())
    }

    private func options(_ session: TermiusImportSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L("导入到分组"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                TextField(L("分组名称"), text: binding(\.groupName, default: "Termius"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 160)
                Spacer()
                Toggle(L("保存密码到凭据库"), isOn: binding(\.importPasswords, default: true))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                Toggle(L("导入私钥"), isOn: binding(\.importKeys, default: true))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                Toggle(L("导入 known_hosts"), isOn: binding(\.importKnownHosts, default: true))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
            }
            HStack(spacing: 8) {
                Toggle(L("同时导入连接历史里未保存的主机（") + String(session.catalogue.history.count) + L(" 条记录）"),
                       isOn: binding(\.includeHistory, default: false))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                    .onChange(of: session.includeHistory) { _ in
                        app.refreshTermiusHosts()
                    }
                Spacer()
                Text(L("已选 ") + String(session.selection.count) + " / " + String(session.hosts.count) + L(" 台"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondary)
                Button(L("全选")) { app.selectAllTermiusHosts() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                Button(L("清空")) { app.deselectAllTermiusHosts() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .disabled(session.selection.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hostList(_ session: TermiusImportSession) -> some View {
        Group {
            if session.hosts.isEmpty {
                VStack(spacing: 6) {
                    Text(L("没有可导入的主机"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Text(L("Termius 的已保存主机列表是空的。可以打开上面的“连接历史”开关，从历史记录里导入。"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(session.hosts) { host in
                            row(host, selected: session.selection.contains(host.id))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ host: TermiusImportedHost, selected: Bool) -> some View {
        Button {
            app.toggleTermiusHost(host.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                Image(systemName: host.keyLabel == nil ? "person.badge.key" : "key.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Text(host.username + "@" + host.hostname + ":" + String(host.port))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let key = host.keyLabel {
                    chip(L("密钥 ") + key, color: Theme.accent)
                } else if host.password != nil {
                    chip(L("密码"), color: Theme.success)
                }
                if host.fromHistory {
                    chip(L("历史"), color: Theme.secondary)
                }
                ForEach(host.tags.prefix(2), id: \.self) { tag in
                    chip(tag, color: Theme.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let session {
                if session.isLoading {
                    Text(session.slowHint ? L("等待钥匙串授权…") : L("读取中…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(session.slowHint ? Theme.warning : Theme.secondary)
                } else if let error = session.errorText, session.catalogue.decryptedCount > 0 {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                } else {
                    Text(selectionHint(session))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            Button(L("重试")) {
                Task { await app.loadTermiusCatalogue() }
            }
            .disabled(session?.isLoading ?? false)
            Button(L("取消")) {
                app.cancelTermiusImport()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            // Deliberately not the default button: a stray Return must not
            // bulk-write dozens of hosts into the catalog while the sheet is open.
            Button(session?.isImporting == true ? L("导入中…") : L("导入")) {
                app.performTermiusImport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(session == nil || session!.isLoading || session!.isImporting || session!.selection.isEmpty || session!.catalogue.decryptedCount == 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func selectionHint(_ session: TermiusImportSession) -> String {
        if session.hosts.isEmpty { return L("没有勾选主机") }
        return L("将新建 ") + String(session.selection.count) + L(" 台主机") + (session.importKeys ? "、" + String(session.catalogue.keys.count) + L(" 个私钥") : "")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<TermiusImportSession, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { app.termiusImport?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                app.termiusImport?[keyPath: keyPath] = newValue
            }
        )
    }
}