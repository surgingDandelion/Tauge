import SwiftUI

/// A small, deliberately restrained instrument-panel vocabulary: monospaced
/// data, squared tags, hairline strokes and a single accent tick. The layout
/// metrics stay exactly as they were; only the surface treatment changes.
enum TechFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Theme {
    /// Cards get a very slight top-to-bottom falloff instead of a flat fill.
    static let cardTop = dynamic(light: 0xFFFFFF, dark: 0x2A2C34)
    static let cardBottom = dynamic(light: 0xFAFAFD, dark: 0x222329)
    /// A touch stronger than `cardStroke`; used where a card needs an edge.
    static let hairline = dynamic(light: 0xD5D5DE, dark: 0x3B3D47)
    static let tagBackground = dynamic(light: 0xF1F1F6, dark: 0x2B2D35)
    static let insetHighlight = dynamic(light: 0xFFFFFF, dark: 0x3A3C46)
    static let techPressed = dynamic(light: 0xE7E7EE, dark: 0x1C1D23)
    static let gridLine = dynamic(light: 0xE8E8EF, dark: 0x2A2B33)
}

/// The shared card surface: gradient fill, one-pixel inner highlight, a hairline
/// border, and a tiny bracket that only appears on hover. Callers keep their own
/// padding and corner radius so the compact geometry is untouched.
struct TechCardSurface: ViewModifier {
    var cornerRadius: CGFloat = 8
    var hovered: Bool = false
    var selected: Bool = false
    var accent: Color = Theme.accent
    var glow: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom],
                                             startPoint: .top,
                                             endPoint: .bottom))
                    // Inset top light. It reads as a machined edge rather than a
                    // second border because it fades out at both ends.
                    VStack {
                        LinearGradient(colors: [Theme.insetHighlight.opacity(0.9),
                                                Theme.insetHighlight.opacity(0)],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                            .frame(height: 1)
                            .padding(.horizontal, 7)
                        Spacer(minLength: 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: selected || hovered ? 1 : 0.7)
            }
            .overlay(alignment: .topLeading) {
                TechCornerBracket()
                    .stroke(selected || hovered ? accent.opacity(0.95) : accent.opacity(0.34),
                            style: StrokeStyle(lineWidth: 1.2, lineCap: .square))
                    .frame(width: 9, height: 9)
                    .padding(3)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: shadowColor, radius: hovered ? 9 : 4, y: hovered ? 3 : 1)
    }

    private var borderColor: Color {
        if selected { return accent.opacity(0.55) }
        if hovered { return accent.opacity(0.38) }
        return Theme.cardStroke
    }

    private var shadowColor: Color {
        if hovered && glow { return accent.opacity(0.16) }
        return Theme.shadow.opacity(0.55)
    }
}

private struct TechCornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A faint measurement grid behind the host area. It is deliberately almost
/// invisible in light mode and only a shade above the dark background: enough
/// to make the canvas read as an instrument surface, not as wallpaper.
struct TechDotGrid: View {
    var spacing: CGFloat = 24
    var dot: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let color = GraphicsContext.Shading.color(Theme.gridLine.opacity(0.9))
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                                 with: color)
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func techCard(cornerRadius: CGFloat = 8,
                  hovered: Bool = false,
                  selected: Bool = false,
                  accent: Color = Theme.accent,
                  glow: Bool = true) -> some View {
        modifier(TechCardSurface(cornerRadius: cornerRadius,
                                 hovered: hovered,
                                 selected: selected,
                                 accent: accent,
                                 glow: glow))
    }
}

/// Squared, monospaced metadata tags. These replace the pill capsules: at 9pt a
/// square corner plus a hairline reads as a label, not as a button.
struct TechTag: View {
    var text: String
    var systemName: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 7.5, weight: .semibold))
            }
            Text(text)
                .font(TechFont.mono(8.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? Theme.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Theme.tagBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(Theme.hairline.opacity(0.75), lineWidth: 0.6)
        )
        .fixedSize()
    }
}

enum TechButtonKind {
    case secondary
    case primary
    case ghost
}

/// Compact label + optional icon for `TechButtonStyle` and menu labels.
struct TechButtonLabel: View {
    var systemName: String?
    var title: String
    var kind: TechButtonKind = .secondary
    var hovering: Bool = false
    var badge: Int = 0
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(title)
                .font(TechFont.mono(10, .medium))
                .lineLimit(1)
            if badge > 0 {
                Text(String(badge))
                    .font(TechFont.mono(8, .bold))
                    .foregroundStyle(kind == .primary ? Theme.accent : Color.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 0.5)
                    .background(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(kind == .primary ? Color.white : Theme.accent)
                    )
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(border, lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary, .ghost: return .primary
        }
    }

    private var background: some ShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.82)],
                                                startPoint: .top,
                                                endPoint: .bottom))
        case .secondary:
            return AnyShapeStyle(LinearGradient(colors: [Theme.cardTop, Theme.cardBottom],
                                                startPoint: .top,
                                                endPoint: .bottom))
        case .ghost:
            return AnyShapeStyle(hovering ? Theme.rowHover : Color.clear)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return Theme.accent.opacity(0.65)
        case .secondary: return hovering ? Theme.accent.opacity(0.38) : Theme.hairline.opacity(0.85)
        case .ghost: return .clear
        }
    }
}

struct TechButtonStyle: ButtonStyle {
    var kind: TechButtonKind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(kind == .primary ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(configuration.isPressed ? Theme.techPressed : Color.clear)
            }
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

/// A compact button that owns its hover state, so the technical border lights up
/// before the click instead of only on press.
struct TechActionButton: View {
    var systemName: String?
    var title: String
    var kind: TechButtonKind = .secondary
    var badge: Int = 0
    var isEnabled: Bool = true
    var height: CGFloat = 24
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            TechButtonLabel(systemName: systemName,
                            title: title,
                            kind: kind,
                            hovering: hovering,
                            badge: badge,
                            height: height)
        }
        .buttonStyle(TechButtonStyle(kind: kind))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.1)) { hovering = inside }
        }
    }
}

/// The 30pt host/platform tile, with a faint inner rim and a corner notch.
struct TechIconTile: View {
    var systemName: String
    var tint: Color
    var size: CGFloat = 30
    var hovered: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(hovered ? 0.26 : 0.18),
                                              tint.opacity(hovered ? 0.15 : 0.10)],
                                     startPoint: .top,
                                     endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(tint.opacity(hovered ? 0.55 : 0.35), lineWidth: 0.8)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(tint)
            Rectangle()
                .fill(tint.opacity(hovered ? 0.9 : 0.5))
                .frame(width: 4, height: 1)
                .padding(.top, 3)
                .padding(.trailing, 4)
        }
        .frame(width: size, height: size)
    }
}

/// A status dot with a dark ring so it stays legible on both card colours.
struct TechStatusDot: View {
    var color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: color.opacity(0.5), radius: 2.5)
    }
}
