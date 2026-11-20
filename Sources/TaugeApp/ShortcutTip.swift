import SwiftUI

/// A hover hint that names the control and shows the key chord that does the
/// same thing.
///
/// macOS' own `.help` tooltip is what SwiftUI gives you for free, but it only
/// appears after roughly a second and a half and it is drawn with the system
/// bubble style, which reads as a different app next to Tauge's own chrome.
/// These headers are where the user learns the shortcuts, so the hint has to
/// show up on a normal hover and look like it belongs here.
struct ShortcutTipBubble: View {
    let title: String
    var keys: [String] = []

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
            }
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.cardStroke.opacity(0.9), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 6, y: 2)
        )
        .fixedSize()
    }
}

/// Wraps a control so hovering it reveals the shortcut bubble.
///
/// This is a plain `View` rather than a `ViewModifier` on purpose: the hint
/// state lives in `@ViewState`, and a ViewModifier's storage is not stable
/// enough here for the timer callback to re-render the row it belongs to.
private struct ShortcutTipBox<Content: View>: View {
    let title: String
    let keys: [String]
    /// Which edge of the control the bubble lines up with.
    let horizontal: HorizontalAlignment
    /// Bars pinned to the bottom of the window have to open their hint upwards.
    let below: Bool
    /// Delay before the bubble appears, so sweeping the pointer across a strip
    /// does not flash a row of hints.
    let delay: Double
    @ViewBuilder let content: Content

    @ViewState private var hovering = false
    @ViewState private var visible = false

    var body: some View {
        content
            .overlay(alignment: Alignment(horizontal: horizontal, vertical: below ? .bottom : .top)) {
                if visible {
                    ShortcutTipBubble(title: title, keys: keys)
                        .offset(y: below ? 26 : -26)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { inside in
                hovering = inside
                guard inside else {
                    withAnimation(.easeOut(duration: 0.08)) { visible = false }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard hovering, !visible else { return }
                    withAnimation(.easeOut(duration: 0.12)) { visible = true }
                }
            }
            // The bubble hangs outside the control, so it has to paint over the
            // rows that come after it in the layout.
            .zIndex(visible ? 10 : 0)
    }
}

extension View {
    /// Shows a hint bubble with the control's name and shortcut on hover.
    func shortcutTip(
        _ title: String,
        keys: [String] = [],
        align horizontal: HorizontalAlignment = .center,
        below: Bool = true,
        delay: Double = 0.35
    ) -> some View {
        ShortcutTipBox(
            title: title,
            keys: keys,
            horizontal: horizontal,
            below: below,
            delay: delay
        ) { self }
    }
}
