import AppKit

/// Which displays are currently showing a full-screen window.
///
/// The real notch never has to apologise for being there — it is a hole in the
/// hardware, and macOS letterboxes full-screen content below it. A drawn tab has
/// no such excuse: left alone it would sit on top of full-screen video.
///
/// macOS exposes no "is this display in full screen" query, so this reads the
/// window list instead. On the normal document layer, a window covering an
/// entire display is what full screen looks like from the outside — and the same
/// test catches borderless full-screen games, which never create a Space and
/// would be missed by watching for space changes.
///
/// Window *images* need Screen Recording consent; window *bounds* do not, which
/// is what keeps this permission-free. Ported verbatim from Dictate.
enum FullScreenProbe {
    /// The subset of `screens` that a full-screen window is covering. Frames go
    /// in and come back out in global AppKit coordinates.
    static func coveredDisplays(among screens: [CGRect]) -> [CGRect] {
        guard !screens.isEmpty,
              let listing = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return [] }

        let flip = primaryHeight()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = listing.compactMap { window -> CGRect? in
            // Layer 0 is the ordinary document layer, which is where a
            // full-screen window lives. The menu bar, the Dock and every HUD —
            // this app's own panels included — sit above it. Our own windows
            // (file dialogs included) are excluded outright: the app must
            // never read itself as the thing covering a display.
            guard window[kCGWindowOwnerPID as String] as? Int32 != ownPID,
                  window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowAlpha as String] as? Double ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }

            // Quartz measures down from the top-left of the primary display,
            // AppKit up from its bottom-left.
            return CGRect(
                x: frame.minX,
                y: flip - frame.maxY,
                width: frame.width,
                height: frame.height)
        }

        // A pixel of slack: a window reported a hair short of the display it
        // fills is still filling it.
        return screens.filter { screen in
            windows.contains { $0.insetBy(dx: -1, dy: -1).contains(screen) }
        }
    }

    /// The display AppKit puts at the origin — the number that converts between
    /// the two coordinate systems.
    private static func primaryHeight() -> CGFloat {
        let screens = NSScreen.screens
        return (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.height ?? 0
    }
}
