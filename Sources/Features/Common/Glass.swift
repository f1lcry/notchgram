import SwiftUI

/// Liquid Glass building blocks for the Obsidian design (Session 7).
///
/// Two tiers, chosen deliberately:
/// - **Real Liquid Glass** (`glassIsland`) only for elements that *float* —
///   the scroll-to-bottom FAB, the send button, viewer chrome. The material
///   samples what is behind it, so it earns its keep over scrolling content.
/// - **Painted glass** (`insetGlass`) for structural surfaces — fields,
///   selection pills, bubbles. Deterministic on the pure-black ground, and a
///   whole conversation of live glass bubbles would be paying compositor tax
///   for refraction nobody can see against flat black.
extension View {

    /// A floating Liquid Glass island clipped to `shape`.
    public func glassIsland(
        in shape: some Shape,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: shape)
    }

    /// An inset painted-glass surface: quiet fill plus an edge-light hairline.
    /// `focused` swaps the hairline for the accent ring.
    public func insetGlass(
        cornerRadius: CGFloat,
        fill: Color = Color.white.opacity(0.055),
        focused: Bool = false
    ) -> some View {
        background(fill, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        focused ? Theme.Palette.accent.opacity(0.55) : Theme.Palette.hairline,
                        lineWidth: 1)
            }
    }
}

/// Press feedback for every custom control: a quick, shallow scale — tactile
/// confirmation the UI heard the click, never a bounce.
public struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    public static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Small round icon button for panel chrome (header, composer): quiet by
/// default, a soft glass disc on hover, dented on press.
struct PanelIconButton: View {
    let systemName: String
    var iconSize: CGFloat = 13
    var side: CGFloat = 24
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(
                    isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .frame(width: side, height: side)
                .background(isHovering ? Theme.Palette.surfaceHover : .clear, in: .circle)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.quick, value: isHovering)
    }
}

/// Telegram's "is typing" as motion instead of words-only: three dots
/// breathing in a staggered wave next to the label.
struct TypingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 3, height: 3)
                    .opacity(phase ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
