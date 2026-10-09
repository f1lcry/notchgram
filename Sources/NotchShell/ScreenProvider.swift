import AppKit

/// Where `[ScreenInfo]` comes from. The only reason this is a protocol is so
/// tests can hand the engine a fabricated desktop.
@MainActor
public protocol ScreenProvider {
    func screens() -> [ScreenInfo]
}

/// The real one.
@MainActor
public struct LiveScreenProvider: ScreenProvider {
    public init() {}

    public func screens() -> [ScreenInfo] {
        // Never `NSScreen.main` — it follows the key window, so it points at
        // whatever the user last clicked rather than at anything stable.
        NSScreen.screens.compactMap(Self.info)
    }

    static func info(for screen: NSScreen) -> ScreenInfo? {
        // macOS 26's `cgDirectDisplayID` is Optional; a screen caught
        // mid-reconfiguration has no id yet, and a geometry keyed on "unknown"
        // would collide with the next such screen.
        guard let displayID = screen.cgDirectDisplayID,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cfUUID) as String?
        else { return nil }

        return ScreenInfo(
            uuid: uuid,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea,
            safeAreaTop: screen.safeAreaInsets.top,
            backingScaleFactor: screen.backingScaleFactor)
    }
}

/// A fabricated desktop, for unit tests and for DebugBridge's
/// "pretend I have this topology" mode.
@MainActor
public struct FixtureScreenProvider: ScreenProvider {
    public var fixtures: [ScreenInfo]

    public init(_ fixtures: [ScreenInfo]) { self.fixtures = fixtures }

    public func screens() -> [ScreenInfo] { fixtures }
}

/// The topologies worth having names for. Several of them cannot be produced on
/// demand — closing the lid mid-session, unplugging a monitor while the panel is
/// open — which is exactly why they are fixtures.
public enum ScreenFixtures {
    /// The founder's built-in: 1728×1117 @2x, cut-out 185×32 centred on 864.
    public static let notchedBuiltIn = ScreenInfo(
        uuid: "builtin",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32),
        safeAreaTop: 32,
        backingScaleFactor: 2)

    /// Portrait external, left of the built-in.
    public static let portraitExternal = ScreenInfo(
        uuid: "portrait",
        frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
        visibleFrame: CGRect(x: -1080, y: 0, width: 1080, height: 1895),
        backingScaleFactor: 1)

    /// Landscape external, right of the built-in.
    public static let landscapeExternal = ScreenInfo(
        uuid: "landscape",
        frame: CGRect(x: 1728, y: 37, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1728, y: 37, width: 1920, height: 1055),
        backingScaleFactor: 1)

    /// Small enough that an 880×580 panel does not fit.
    public static let tiny = ScreenInfo(
        uuid: "tiny",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 575),
        backingScaleFactor: 1)

    /// Narrow vertical panel — the case where a tab at half a real notch's
    /// width would be disproportionate.
    public static let narrow = ScreenInfo(
        uuid: "narrow",
        frame: CGRect(x: 0, y: 0, width: 600, height: 1920),
        visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 1895),
        backingScaleFactor: 1)

    /// A display reporting a menu bar of zero — what a secondary screen looks
    /// like with "Displays have separate Spaces" switched off.
    public static let noMenuBar = ScreenInfo(
        uuid: "no-menu-bar",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 1)

    /// Auxiliary areas present but `safeAreaTop == 0` — what a notched display
    /// reports while the menu bar is auto-hidden. Treating that as "no notch"
    /// is the bug this fixture exists to catch.
    public static let notchedWithHiddenMenuBar = ScreenInfo(
        uuid: "hidden-menu-bar",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        auxiliaryTopLeft: CGRect(x: 0, y: 1085, width: 771, height: 32),
        auxiliaryTopRight: CGRect(x: 956, y: 1085, width: 772, height: 32),
        safeAreaTop: 0,
        backingScaleFactor: 2)

    /// Today's real desk.
    public static let founderDesk = [notchedBuiltIn, portraitExternal, landscapeExternal]
    /// Lid closed: the built-in is absent from `NSScreen.screens` entirely, so
    /// "is this the built-in" is never a valid test for "does this have a notch".
    public static let clamshell = [portraitExternal, landscapeExternal]
    public static let twoExternals = [landscapeExternal, portraitExternal]
}
