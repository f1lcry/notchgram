import CoreGraphics
import Foundation

/// Everything `NotchGeometryEngine` needs to know about one display, as a plain
/// value.
///
/// This type is the testability seam. Dictate reads `NSScreen` (and app
/// settings) directly inside its geometry function, which means every display
/// topology — clamshell, hot-unplug, a mirrored pair, a 600×1920 vertical panel
/// — can only be exercised by physically rearranging hardware. Behind a value
/// type they are all just fixtures.
public struct ScreenInfo: Equatable, Hashable, Sendable, Identifiable {
    /// Display **UUID**, never `CGDirectDisplayID`: the latter is reassigned on
    /// reconfiguration, so anything persisted against it follows the wrong
    /// screen after a dock/undock.
    public let uuid: String
    public let frame: CGRect
    /// Excludes the menu bar and the Dock. `frame.maxY - visibleFrame.maxY` is
    /// this screen's menu-bar thickness, which is 0 on a secondary display when
    /// "Displays have separate Spaces" is off.
    public let visibleFrame: CGRect
    /// Non-nil **only** on a display with a real cut-out. Together with
    /// `auxiliaryTopRight` this is the correct existence test — not
    /// `safeAreaInsets.top > 0`, which tracks menu-bar *visibility* and reports
    /// 0 whenever the menu bar is auto-hidden. (That is the bug boring.notch
    /// ships.)
    public let auxiliaryTopLeft: CGRect?
    public let auxiliaryTopRight: CGRect?
    public let safeAreaTop: CGFloat
    public let backingScaleFactor: CGFloat

    public var id: String { uuid }

    public init(
        uuid: String,
        frame: CGRect,
        visibleFrame: CGRect,
        auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil,
        safeAreaTop: CGFloat = 0,
        backingScaleFactor: CGFloat = 2
    ) {
        self.uuid = uuid
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
        self.safeAreaTop = safeAreaTop
        self.backingScaleFactor = backingScaleFactor
    }

    /// This screen's menu-bar thickness, with a fallback for the "separate
    /// Spaces off" case where a secondary display reports none.
    public var menuBarHeight: CGFloat {
        let inset = frame.maxY - visibleFrame.maxY
        return inset > 0 ? inset : 24
    }

    /// The physical cut-out, or nil. Both auxiliary areas must be present: a
    /// display mid-reconfiguration can report one and not the other.
    public var physicalNotch: CGRect? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return nil }
        let width = frame.width - left.width - right.width
        let height = safeAreaTop
        guard width > 0, height > 0 else { return nil }
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height)
    }

    /// What a rebuild diffs on. Two snapshots that agree here describe the same
    /// desktop, and `didChangeScreenParameters` fires several times for one
    /// physical change — rebuilding on each makes the panel visibly flash.
    public var reconfigurationKey: String {
        let f = frame, v = visibleFrame
        return "\(uuid)|\(f.minX),\(f.minY),\(f.width),\(f.height)"
            + "|\(v.minX),\(v.minY),\(v.width),\(v.height)"
            + "|\(safeAreaTop)|\(physicalNotch != nil)"
    }
}

/// The knobs `NotchGeometryEngine` reads. Injected rather than read from
/// `UserDefaults` inside the engine, so a fixture can pin them.
public struct GeometrySettings: Equatable, Sendable {
    /// Founder's Telegram Desktop measured 890×584; 880×580 is the default
    /// (D8). Clamped per screen — Dictate never implemented the clamp, and an
    /// 880-wide panel does not fit a 800×600 display.
    public var panelSize: CGSize
    /// Forces every screen to draw a synthetic tab, including one with a real
    /// cut-out. This is a DebugBridge switch: the synthetic path is the primary
    /// dev surface (the founder works on external displays) and must be
    /// reachable on the notched built-in too.
    public var forceSynthetic: Bool

    public static let minPanelWidth: CGFloat = 640
    public static let minPanelHeight: CGFloat = 420

    public init(
        panelSize: CGSize = CGSize(width: 880, height: 580),
        forceSynthetic: Bool = false
    ) {
        self.panelSize = panelSize
        self.forceSynthetic = forceSynthetic
    }
}
