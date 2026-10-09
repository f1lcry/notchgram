import SwiftUI

/// The slab itself: the shape, the fold animation, and nothing else — Dictate's
/// chrome, taken as-is. Everything inside is somebody else's problem.
///
/// The window never moves or resizes — all of the motion here is the slab
/// growing inside a still, panel-sized window, clipped to `NotchSlabShape`.
/// No drawn shadow, no stroke, no glass: Session 2's two-layer shadow needed an
/// oversized window to blur into, and the pair of them is exactly what read as
/// "the window looks cut off". A plain black slab against the screen edge needs
/// no apology, which is the whole Dictate lesson.
///
/// Content is laid out at full panel size at all times and merely faded,
/// blurred and clipped while folded — laying it out at the slab's animating
/// size made the entire chat UI reflow on every frame of the spring.
public struct NotchChromeView<Content: View>: View {
    let state: PanelState
    let geometry: NotchGeometry
    /// What the slab is filled with while open. Collapsed it is always pure
    /// black — it has to read as the notch — but an open panel filled with
    /// black framed the UI in black bars (the top strip over the menu bar,
    /// the content gutters). Filling with the app's own background makes the
    /// strip and gutters read as one surface with the content.
    let expandedFill: Color
    @ViewBuilder var content: () -> Content

    public init(
        state: PanelState,
        geometry: NotchGeometry,
        expandedFill: Color = .black,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.state = state
        self.geometry = geometry
        self.expandedFill = expandedFill
        self.content = content
    }

    /// Shape radii, and the content insets they dictate. `NotchSlabShape`'s
    /// body runs at `x = topRadius` below the top flare — the slab is
    /// *narrower than its rect* everywhere but the very top edge. Content laid
    /// out to the full rect therefore loses exactly `topRadius` off each side
    /// to the clip (the founder's "avatars are clipped at the side"); Dictate never
    /// shows this only because its content padding (14) exceeds the radius.
    static var topRadius: CGFloat { 11 }
    static var bottomRadius: CGFloat { 22 }
    static var contentSideInset: CGFloat { topRadius }
    /// Clears the bottom corner arcs so the composer's corners are not shaved.
    static var contentBottomInset: CGFloat { 10 }

    private var shape: NotchSlabShape {
        NotchSlabShape(
            topRadius: state.expanded ? Self.topRadius : 0,
            bottomRadius: state.expanded ? Self.bottomRadius : geometry.collapsedBottomRadius)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            shape.fill(state.expanded ? expandedFill : Color.black)

            if state.mounted {
                VStack(spacing: 0) {
                    // Keep the anchor row clear: on a physical notch content
                    // would hide behind the cut-out, and on a drawn tab it
                    // would collide with the menu bar.
                    Color.clear.frame(height: geometry.topStripHeight)
                    content()
                        .padding(.horizontal, Self.contentSideInset)
                        .padding(.bottom, Self.contentBottomInset)
                }
                .frame(
                    width: geometry.panel.width,
                    height: geometry.panel.height,
                    alignment: .top)
                .opacity(state.expanded ? 1 : 0)
                .blur(radius: state.expanded ? 0 : 5)
                .allowsHitTesting(state.expanded)
            }
        }
        .frame(
            width: state.expanded ? geometry.panel.width : geometry.collapsed.width,
            height: state.expanded ? geometry.panel.height : geometry.collapsed.height,
            alignment: .top)
        // Without this the chat UI keeps drawing outside the shrinking slab,
        // which reads as the panel turning into a plain rectangle halfway
        // through the fold.
        .clipShape(shape)
        // A flexible top-pinned frame, not VStack + Spacer: while the unfold
        // spring overshoots, the slab is momentarily *taller than the window*,
        // and the old stack let it settle centred — the whole slab slid down
        // ~1–2 pt and a sliver of menu bar peeked over its top edge (the
        // founder's "a strip"). A frame with explicit `.top` alignment pins
        // the top edge to the screen edge no matter what size the spring is
        // passing through; the overshoot spends itself below the bottom edge,
        // clipped by the window.
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top)
        .frame(
            width: geometry.panel.width,
            height: geometry.panel.height,
            alignment: .top)
    }
}
