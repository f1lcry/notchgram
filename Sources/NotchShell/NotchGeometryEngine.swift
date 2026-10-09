import CoreGraphics
import Foundation

/// `[ScreenInfo] × GeometrySettings → [NotchGeometry]`, and nothing else.
///
/// Pure on purpose. Every display topology that matters — clamshell, a notched
/// built-in beside a portrait external, two notch-less externals, a tiny
/// 800×600 projector, a 600×1920 vertical panel, mirrored duplicates, no screens
/// at all — is a fixture here rather than an afternoon of replugging cables.
/// The topologies that *cannot* be exercised unattended (hot-unplug, closing the
/// lid) are the ones this matters most for.
public enum NotchGeometryEngine {

    /// CONCEPT.md asks for a drawn tab "roughly half the width of a real one".
    /// Dictate draws it **full** width, so a naive port silently violates the
    /// requirement — hence the explicit ratio (D14).
    static let syntheticWidthRatio: CGFloat = 0.5
    static let syntheticMinWidth: CGFloat = 88
    /// A projector or a narrow vertical panel should not get a tab running
    /// nearly half its width.
    static let syntheticMaxWidthRatio: CGFloat = 0.4
    static let syntheticMinHeight: CGFloat = 10
    static let syntheticMaxHeight: CGFloat = 16
    /// Used only when no screen anywhere has a real cut-out to copy — roughly
    /// the 14"/16" MacBook one.
    static let fallbackNotchWidth: CGFloat = 200

    public static func geometries(
        for screens: [ScreenInfo],
        settings: GeometrySettings = GeometrySettings()
    ) -> [NotchGeometry] {
        guard !screens.isEmpty else { return [] }

        // Every drawn tab copies the real cut-out, so the app reads as one
        // feature spread across the desk rather than two that merely look alike.
        let referenceNotchWidth = screens.compactMap(\.physicalNotch).first?.width
            ?? fallbackNotchWidth

        return screens.map { screen in
            let usePhysical = !settings.forceSynthetic && screen.physicalNotch != nil
            let notch = usePhysical
                ? screen.physicalNotch!
                : syntheticNotch(on: screen, referenceWidth: referenceNotchWidth)

            return NotchGeometry(
                screenUUID: screen.uuid,
                style: usePhysical ? .physical : .synthetic,
                screen: screen.frame,
                visibleFrame: screen.visibleFrame,
                notch: notch,
                panel: panelRect(on: screen, settings: settings),
                menuBarHeight: screen.menuBarHeight)
        }
    }

    /// Half a real notch wide, half a menu bar tall, centred on the screen.
    static func syntheticNotch(on screen: ScreenInfo, referenceWidth: CGFloat) -> CGRect {
        let width = clamp(
            (referenceWidth * syntheticWidthRatio).rounded(),
            min: syntheticMinWidth,
            max: max(syntheticMinWidth, screen.frame.width * syntheticMaxWidthRatio))
        let height = clamp(
            (screen.menuBarHeight * 0.5).rounded(),
            min: syntheticMinHeight,
            max: syntheticMaxHeight)

        return CGRect(
            x: (screen.frame.midX - width / 2).rounded(),
            y: screen.frame.maxY - height,
            width: width,
            height: height)
    }

    /// The panel frame, clamped to fit this screen (D8's "screen-safe max",
    /// which Dictate never implemented).
    ///
    /// Note the top edge uses `frame`, not `visibleFrame`: the slab is *meant*
    /// to overlap the menu bar. The bottom is limited by `visibleFrame.minY` so
    /// the panel never runs under the Dock.
    static func panelRect(on screen: ScreenInfo, settings: GeometrySettings) -> CGRect {
        let maxWidth = max(GeometrySettings.minPanelWidth, screen.frame.width - 48)
        let availableHeight = screen.frame.maxY - screen.visibleFrame.minY - 16
        let maxHeight = max(GeometrySettings.minPanelHeight, availableHeight)

        // If even the floor does not fit, still create the panel and let it
        // clip. A missing tab reads as a crash; a slightly clipped one reads as
        // a small screen.
        let width = clamp(settings.panelSize.width, min: GeometrySettings.minPanelWidth, max: maxWidth)
        let height = clamp(settings.panelSize.height, min: GeometrySettings.minPanelHeight, max: maxHeight)

        let x = clamp(
            screen.frame.midX - width / 2,
            min: screen.frame.minX,
            max: max(screen.frame.minX, screen.frame.maxX - width))

        return CGRect(x: x.rounded(), y: screen.frame.maxY - height, width: width, height: height)
    }

    static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }
}

/// Decides whether a `didChangeScreenParameters` burst describes a real change.
///
/// Clamshell fires the notification several times inside a second; rebuilding on
/// each one makes the panel visibly flash three to five times. Diffing the
/// snapshot means a rebuild happens exactly once per real change, and zero times
/// for an identical one — which also covers the notifications macOS emits for
/// wallpaper and colour-profile changes.
public struct ScreenConfiguration: Equatable, Sendable {
    public let key: String

    public init(_ screens: [ScreenInfo]) {
        // Order-independent: macOS does not promise a stable ordering of
        // `NSScreen.screens`, and a reordered array is not a reconfiguration.
        key = screens.map(\.reconfigurationKey).sorted().joined(separator: ";")
    }
}
