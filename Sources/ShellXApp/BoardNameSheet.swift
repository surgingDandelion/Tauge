import SwiftUI
import ShellXKit

/// Asked once, when a workspace assembled by dragging one tab onto another is
/// saved for the first time: until it has a name it only lives in the tab strip.
struct BoardNameSheet: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var focused: Bool

    /// Edited in place, so the sheet's own copy is the single source of truth
    /// the commit reads back.
    private var name: Binding<String> {
        Binding(get: { app.boardNamePrompt?.name ?? "" },
                set: { value in app.boardNamePrompt?.name = value })
    }

    private var canSave: Bool {
        !(app.boardNamePrompt?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text(L("这两个终端已经并排打开。起个名字，它就会留在工作区列表里，下次一键恢复；不保存关掉也没关系。"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("工作区名称"), text: name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commit() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
            footer
        }
        .frame(width: 400)
        .background(Theme.windowBackground)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1").foregroundStyle(Theme.accent)
            Text(L("保存工作区")).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(L("⌘S 保存到工作区列表"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button(L("取消")) { app.cancelBoardNamePrompt() }
                .keyboardShortcut(.cancelAction)
            Button(L("保存")) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func commit() {
        guard canSave else { return }
        app.commitBoardNamePrompt()
    }
}

/// Edits metadata for an existing workspace without touching its panes.
struct BoardEditorView: View {
    @EnvironmentObject private var app: AppState
    @ViewState private var board: BoardDefinition

    init(board: BoardDefinition) {
        _board = ViewState(wrappedValue: board)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x3")
                    .foregroundStyle(Color(hex: board.colorHex) ?? Theme.accent)
                Text(L("编辑工作区"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("取消")) { app.editingBoard = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    app.updateBoard(board)
                    app.editingBoard = nil
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            Form {
                TextField(L("工作区名称"), text: $board.name)
                ColorChoicePicker(colorHex: $board.colorHex)
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 220)
        .background(Theme.windowBackground)
    }
}
