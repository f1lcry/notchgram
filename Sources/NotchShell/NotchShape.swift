import SwiftUI

/// The slab's outline: a rectangle hanging off the top edge of the screen,
/// flush where it meets the edge, rounded at the bottom, with concave fillets
/// at the top corners so the black flows out of the notch instead of ending in
/// a hard step. Ported from Dictate (which calibrated the proportions against
/// DynamicNotchKit).
///
/// Session 2 shipped a "mushroom" here — a stem-and-cap outline that kept the
/// menu bar visible while the panel was open. The founder's verdict: the panel
/// is transient, hiding the menu bar while it is open is fine, and the mushroom
/// read as broken. This is the simple dropdown it replaced.
///
/// Both radii animate. Collapsed, `topRadius` is 0 and `bottomRadius` matches
/// the anchor, so the outline degenerates to the plain bottom-rounded tab — the
/// spring morphs one into the other with no crossfade.
struct NotchSlabShape: Shape {
    /// Concave fillet where the slab leaves the screen edge. 0 while collapsed.
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(topRadius, rect.width / 2))
        let br = max(0, min(bottomRadius, rect.width / 2 - r, rect.height - r))
        let left = rect.minX + r
        let right = rect.maxX - r
        let top = rect.minY
        let bottom = rect.maxY

        var path = Path()
        // Start at the screen edge and curve inwards: tangent to the top edge
        // where it leaves, tangent to the side where it arrives.
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addQuadCurve(
            to: CGPoint(x: left, y: top + r),
            control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - br))
        path.addQuadCurve(
            to: CGPoint(x: left + br, y: bottom),
            control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - br, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: right, y: bottom - br),
            control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: top + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: top),
            control: CGPoint(x: right, y: top))
        path.closeSubpath()
        return path
    }
}
