import SwiftUI
import TaugeKit

struct WindowControlStrip: View {
    let isFullScreen: Bool
    let isWindowActive: Bool
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onToggleFullScreen: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            control(
                "close", title: L("关闭窗口"), symbol: "xmark",
                tint: Theme.dynamic(light: 0xFF5F57, dark: 0xFF665D),
                action: onClose
            )
            control(
                "minimize", title: L("最小化窗口"), symbol: "minus",
                tint: Theme.dynamic(light: 0xFEBC2E, dark: 0xFFC243),
                enabled: !isFullScreen, action: onMinimize
            )
            control(
                "fullscreen", title: isFullScreen ? L("退出全屏") : L("进入全屏"),
                symbol: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                tint: Theme.dynamic(light: 0x28C840, dark: 0x38CB4D),
                action: onToggleFullScreen
            )
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .fixedSize()
    }

    private func control(
        _ name: String, title: String, symbol: String, tint: Color,
        enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        let accented = enabled && (isWindowActive || hovering)
        let inactiveFill = Theme.dynamic(light: 0xDDDFE4, dark: 0x414650)
        let inactiveBorder = Theme.dynamic(light: 0xCBCED5, dark: 0x565C67)

        return Button(action: action) {
            Circle()
                .fill(accented ? tint : inactiveFill)
                .overlay {
                    Circle().strokeBorder(accented ? Color.black.opacity(0.15) : inactiveBorder, lineWidth: 0.75)
                }
                .overlay {
                    if hovering && enabled {
                        Image(systemName: symbol)
                            .font(.system(size: 6, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.70))
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("tauge-window-\(name)")
        .accessibilityLabel(Text(title))
        .help(title)
    }
}
