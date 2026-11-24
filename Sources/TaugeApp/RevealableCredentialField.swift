import SwiftUI
import TaugeKit

/// The masked and revealed controls edit the same value. Visibility is local
/// to this field and is never persisted with the host or proxy.
struct RevealableCredentialField: View {
    private enum Field: Hashable { case masked, revealed }

    let title: String
    @Binding var text: String
    var isPassphrase = false
    /// Embedding forms can provide their own border around the field and
    /// reveal button. Keep AppKit's normal field style for the other editors.
    var usesPlainEditorStyle = false
    @ViewState private var isRevealed = false
    @FocusState private var focusedField: Field?

    private var toggleLabel: String {
        if isPassphrase { return isRevealed ? L("隐藏口令") : L("显示口令") }
        return isRevealed ? L("隐藏密码") : L("显示密码")
    }

    var body: some View {
        HStack(spacing: 4) {
            if usesPlainEditorStyle {
                valueField.textFieldStyle(.plain)
            } else {
                valueField.textFieldStyle(.roundedBorder)
            }

            Button {
                let wasEditing = focusedField != nil
                isRevealed.toggle()
                if wasEditing { focusedField = isRevealed ? .revealed : .masked }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(toggleLabel)
            .help(toggleLabel)
        }
        .onDisappear { isRevealed = false }
    }

    private var valueField: some View {
        Group {
            if isRevealed {
                TextField(title, text: $text)
                    .disableAutocorrection(true)
                    .focused($focusedField, equals: .revealed)
            } else {
                SecureField(title, text: $text)
                    .focused($focusedField, equals: .masked)
            }
        }
        .labelsHidden()
    }
}

/// A form keeps its own draft until Save. An untouched blank value must not
/// erase a credential that was not available when the form opened.
struct SavedCredentialDraft {
    var text = ""
    private var original = ""

    mutating func load(from store: SecretStore, account: SecretAccount) throws {
        original = try store.secret(for: account) ?? ""
        text = original
    }

    func save(to store: SecretStore, account: SecretAccount, remember: Bool, wasRemembered: Bool) throws {
        if remember {
            guard text != original else { return }
            try store.setSecret(text.isEmpty ? nil : text, for: account)
        } else if wasRemembered || !original.isEmpty {
            // Record a deletion even when an older keychain item could not be
            // read, so it cannot be restored after the user opts out.
            try store.setSecret(nil, for: account)
        }
    }
}
