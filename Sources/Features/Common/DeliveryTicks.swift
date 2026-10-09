import SwiftUI

/// Telegram/WhatsApp-style delivery ticks: one tick "reached the server",
/// two overlapped ticks "read by the peer".
///
/// Drawn as a `Path`, not typeset as "✓✓": two checkmark characters carry a
/// full glyph advance each, so they land far apart and read as two separate
/// symbols instead of one state. Overlap is the whole idiom — the second
/// tick's vertex rides on the first one's rising arm.
struct DeliveryTicks: View {
    /// `false` — sent (single tick), `true` — read (double tick).
    var read: Bool
    var color: Color

    /// Geometry in points, at the meta line's scale.
    private static let tickWidth: CGFloat = 9.5
    private static let tickHeight: CGFloat = 7
    /// Horizontal distance between the two ticks of a pair.
    private static let pairShift: CGFloat = 4.2

    var body: some View {
        TickPairShape(double: read, shift: Self.pairShift)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .frame(
                width: Self.tickWidth + (read ? Self.pairShift : 0),
                height: Self.tickHeight)
    }
}

private struct TickPairShape: Shape {
    let double: Bool
    let shift: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = double ? rect.width - shift : rect.width
        // The short down-stroke sits at ~1/3 of the width; the long rising
        // arm runs to the top-right corner.
        func tick(at x: CGFloat) {
            path.move(to: CGPoint(x: x, y: rect.midY + rect.height * 0.13))
            path.addLine(to: CGPoint(x: x + width * 0.32, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + width, y: rect.minY))
        }
        tick(at: rect.minX)
        if double { tick(at: rect.minX + shift) }
        return path
    }
}
