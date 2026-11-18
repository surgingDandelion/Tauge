import Foundation
import ShellXKit

/// Preview state for the Termius import sheet.
struct TermiusImportSession: Identifiable {
    let id = UUID()
    var catalogue = TermiusCatalogue()
    var hosts: [TermiusImportedHost] = []
    var selection: Set<String> = []
    var includeHistory = false
    var importKeys = true
    var importKnownHosts = true
    var importPasswords = true
    var groupName = "Termius"
    var isLoading = true
    var slowHint = false
    var isImporting = false
    var errorText: String?
    var sourcePath: String { catalogue.sourceDirectory }
    var hasData: Bool { !catalogue.savedHosts.isEmpty || !catalogue.history.isEmpty || !catalogue.keys.isEmpty }
}

extension AppState {
    /// Opens the Termius import sheet and starts decrypting the local vault.
    func beginTermiusImport() {
        termiusImport = TermiusImportSession()
        Task { await loadTermiusCatalogue() }
    }

    /// Decrypts the vault, optionally with a key the user pasted into the sheet.
    func loadTermiusCatalogue(keyText: String? = nil) async {
        guard var session = termiusImport else { return }
        let sessionID = session.id
        session.isLoading = true
        session.slowHint = false
        session.errorText = nil
        termiusImport = session

        // A keychain lookup for another app's item can sit on a system prompt that
        // may end up on another Space. Keep the sheet explainable and never let the
        // spinner run forever without telling the user what to do.
        let hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, var current = self.termiusImport, current.id == sessionID, current.isLoading else { return }
            current.slowHint = true
            self.termiusImport = current
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, var current = self.termiusImport, current.id == sessionID, current.isLoading else { return }
            current.isLoading = false
            current.slowHint = false
            current.errorText = "读取 Termius 数据库超时。系统可能弹出了钥匙串授权提示，请点“始终允许”后重试；也可以粘贴密钥手动读取。"
            self.termiusImport = current
        }
        defer {
            hintTask.cancel()
            timeoutTask.cancel()
        }

        do {
            let catalogue = try await Task.detached(priority: .userInitiated) { () -> TermiusCatalogue in
                let key: [UInt8]
                if let keyText, !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    key = try TermiusVaultReader.decodeKey(keyText)
                } else {
                    key = try TermiusVaultReader.localKey()
                }
                return try TermiusVaultReader.read(key: key)
            }.value
            guard var updated = termiusImport, updated.id == sessionID else { return }
            updated.catalogue = catalogue
            updated.hosts = catalogue.mergedHosts(includeHistory: updated.includeHistory)
            updated.selection = Set(updated.hosts.map(\.id))
            updated.isLoading = false
            updated.errorText = catalogue.decryptedCount > 0
                ? nil
                : "数据库里没有解密出任何记录。若 Termius 从未登录过，或本地库刚刚被重建，请先在 Termius 里登录一次再导入。"
            termiusImport = updated
        } catch {
            guard var updated = termiusImport, updated.id == sessionID else { return }
            updated.isLoading = false
            updated.slowHint = false
            updated.errorText = error.localizedDescription
            termiusImport = updated
        }
    }

    /// Recomputes the host preview when a switch changes.
    func refreshTermiusHosts() {
        guard var session = termiusImport else { return }
        session.hosts = session.catalogue.mergedHosts(includeHistory: session.includeHistory)
        let available = Set(session.hosts.map(\.id))
        session.selection = session.selection.intersection(available)
        if session.selection.isEmpty {
            session.selection = available
        }
        termiusImport = session
    }

    func toggleTermiusHost(_ id: String) {
        guard var session = termiusImport else { return }
        if session.selection.contains(id) {
            session.selection.remove(id)
        } else {
            session.selection.insert(id)
        }
        termiusImport = session
    }

    func selectAllTermiusHosts() {
        guard var session = termiusImport else { return }
        session.selection = Set(session.hosts.map(\.id))
        termiusImport = session
    }

    func deselectAllTermiusHosts() {
        guard var session = termiusImport else { return }
        session.selection.removeAll()
        termiusImport = session
    }

    func cancelTermiusImport() {
        termiusImport = nil
    }

    /// Writes the selected hosts, keys and known_hosts into the catalog.
    func performTermiusImport() {
        guard var session = termiusImport, !session.isImporting else { return }
        session.isImporting = true
        session.errorText = nil
        termiusImport = session

        let options = TermiusImportOptions(
            groupName: session.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Termius" : session.groupName,
            includeHistoryHosts: session.includeHistory,
            importKeys: session.importKeys,
            importKnownHosts: session.importKnownHosts,
            importPasswords: session.importPasswords,
            selectedHostIDs: session.selection
        )

        do {
            let summary = try TermiusImporter.apply(
                catalogue: session.catalogue,
                options: options,
                store: store,
                secrets: environment.secrets
            )
            reloadCatalog()
            termiusImport = nil
            presentMessage("Termius 导入完成", importSummaryText(summary))
        } catch {
            guard var failed = termiusImport else { return }
            failed.isImporting = false
            failed.errorText = error.localizedDescription
            termiusImport = failed
        }
    }

    private func importSummaryText(_ summary: TermiusImportSummary) -> String {
        var lines = [
            "分组：" + summary.groupName,
            "新建主机 " + String(summary.importedHosts) + " 台",
            "导入私钥 " + String(summary.importedKeys) + " 个",
            "导入 known_hosts " + String(summary.importedKnownHosts) + " 条"
        ]
        if summary.passwordsStored > 0 {
            lines.append("保存密码 " + String(summary.passwordsStored) + " 组（钥匙串）")
        }
        if !summary.skippedHosts.isEmpty {
            lines.append("已存在、跳过的同主机 " + String(summary.skippedHosts.count) + " 台")
        }
        if !summary.skippedKeys.isEmpty {
            lines.append("已存在的私钥 " + String(summary.skippedKeys.count) + " 个")
        }
        if !summary.failedKeys.isEmpty {
            lines.append("无法写入的私钥：" + summary.failedKeys.joined(separator: "；"))
        }
        return lines.joined(separator: "\n")
    }
}