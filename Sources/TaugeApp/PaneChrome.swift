import SwiftUI
import AppKit

// MARK: - Panel chrome

/// 22x22 icon button used in every SFTP panel header. Every control in a header
/// has the same box, so the rows line up instead of drifting by a few points per
/// control (the old mix of plain buttons, borderless menus, small toggles and
/// dividers each had a different intrinsic height).
struct PaneIconButton: View {
    var systemName: String
    var help: String
    var isOn: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        if isOn { return Theme.accent }
        return isEnabled ? Theme.secondary : Theme.secondary.opacity(0.32)
    }

    private var background: Color {
        if isOn { return Theme.accent.opacity(0.15) }
        return hovering && isEnabled ? Theme.rowHover : Color.clear
    }
}

/// A menu with the same 22x22 hit box as PaneIconButton.
struct PaneMenuButton<Content: View>: View {
    var systemName: String
    var help: String
    var isEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    @ViewState private var hovering = false

    var body: some View {
        Menu { content() } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.secondary : Theme.secondary.opacity(0.32))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering && isEnabled ? Theme.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct PaneDividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator.opacity(0.6))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }
}

/// Shared header bar: fixed height, hairline bottom edge.
struct PaneHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 1) { content() }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(Theme.headerBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.separator.opacity(0.55))
                    .frame(height: 0.5)
            }
    }
}

/// Editable path field. Monospaced so paths of different lengths stop jittering
/// while typing; the header already owns the refresh action, so the field keeps
/// its full width for the path itself.
struct PanePathField: View {
    var placeholder: String
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary.opacity(0.65))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10.5, design: .monospaced))
                .disabled(!isEnabled)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 0.5)
        )
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }
}

/// Small status dot used by pane headers.
struct PaneStatusDot: View {
    var isConnected: Bool
    var isBusy: Bool = false

    var body: some View {
        Circle()
            .fill(isBusy ? Theme.warning : (isConnected ? Theme.success : Theme.secondary.opacity(0.4)))
            .frame(width: 5, height: 5)
    }
}
