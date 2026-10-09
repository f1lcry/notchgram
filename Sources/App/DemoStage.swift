#if DEBUG
import Observation
import SwiftUI

/// Demo-mode stagecraft for the docs recording (DebugBridge `setBackdrop`).
///
/// The panel window is transparent outside the slab, and a window-scoped
/// recording (`screencapture -l`) renders transparency as black — the black
/// slab unfolding on black is invisible. With the backdrop on, the window
/// paints a generated wallpaper and a bare menu-bar band behind the slab, so
/// the recording never needs the real desktop (nor anything on it).
@MainActor
@Observable
final class DemoStage {
    static let shared = DemoStage()
    var showsBackdrop = false
}

struct DemoStageView<Content: View>: View {
    let geometry: NotchGeometry
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            if DemoStage.shared.showsBackdrop {
                DemoBackdrop(menuBarHeight: geometry.topStripHeight)
                    .allowsHitTesting(false)
            }
            content()
        }
    }
}

/// A dark, quiet wallpaper: two soft colour fields under a translucent
/// menu-bar band with nothing in it.
private struct DemoBackdrop: View {
    let menuBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.09, blue: 0.15),
                         Color(red: 0.10, green: 0.06, blue: 0.17)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Color(red: 0.39, green: 0.82, blue: 1.0).opacity(0.30), .clear],
                center: UnitPoint(x: 0.18, y: 0.95), startRadius: 0, endRadius: 520)
            RadialGradient(
                colors: [Color(red: 0.62, green: 0.42, blue: 0.95).opacity(0.28), .clear],
                center: UnitPoint(x: 0.88, y: 0.35), startRadius: 0, endRadius: 480)
            Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(height: menuBarHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                }
        }
    }
}
#endif
