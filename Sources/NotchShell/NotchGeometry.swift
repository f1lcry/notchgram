import CoreGraphics
import Foundation

/// Where one screen's anchor is, and the frame of the panel that hangs off it.
///
/// The MacBook's cut-out is one kind of anchor; every display without one gets
/// a drawn tab that behaves identically (D14). There is one geometry per screen
/// (D15), because the pointer spends its day on whichever monitor is being
/// worked on and a panel you have to travel to is a panel you stop using.
///
/// **The window built from this never changes frame.** All motion is a SwiftUI
/// spring inside a still window, clipped to the slab. Animating the frame of the
/// window that owns the hover target makes it oscillate and chase the pointer —
/// which is also why a panel-size change is a full rebuild while collapsed, not
/// a `setFrame`.
public struct NotchGeometry: Equatable, Sendable, Identifiable {
    public enum Style: String, Equatable, Sendable {
        /// The physical cut-out on a MacBook display.
        case physical
        /// A tab drawn where a display has no cut-out to borrow.
        case synthetic
    }

    public let screenUUID: String
    public let style: Style
    /// The whole screen, global coordinates. Used to tell which display the
    /// pointer is on.
    public let screen: CGRect
    public let visibleFrame: CGRect
    /// The anchor: the cut-out, or the tab standing in for it.
    public let notch: CGRect
    /// The **slab** frame: pinned to the top edge, centred on the screen. This
    /// is the visible panel and every hover rect derives from it. The NSPanel
    /// itself uses `window`, which is larger.
    public let panel: CGRect
    /// Height of the menu bar on this screen (0 when it reports none).
    public let menuBarHeight: CGFloat

    public var id: String { screenUUID }

    public init(
        screenUUID: String,
        style: Style,
        screen: CGRect,
        visibleFrame: CGRect,
        notch: CGRect,
        panel: CGRect,
        menuBarHeight: CGFloat = 0
    ) {
        self.screenUUID = screenUUID
        self.style = style
        self.screen = screen
        self.visibleFrame = visibleFrame
        self.notch = notch
        self.panel = panel
        self.menuBarHeight = menuBarHeight
    }

    /// The NSPanel frame **is** the slab frame — Dictate's model, restored in
    /// Session 5. Session 2's 72 pt "shadow margin" existed to give a drawn
    /// shadow room to blur; with no drawn shadow (Dictate paints none) the
    /// margin was just a large invisible sheet whose edges read as the window
    /// being cut off, and whose hit-testing needed its own carve-up.
    public var window: CGRect { panel }

    // MARK: - Collapsed slab

    /// The slab at rest. It folds into the anchor and stays there rather than
    /// being hidden, so the spring always starts and ends somewhere real — a
    /// window ordered out mid-animation is what makes these panels look cheap.
    public var collapsed: CGSize {
        switch style {
        case .physical:
            // Inset a hair so a rounding error can never leave a black sliver
            // poking out from behind the real notch.
            CGSize(width: notch.width - 2, height: notch.height - 1)
        case .synthetic:
            // Nothing to hide behind — the tab *is* what you see, so it has to
            // be exactly the size it advertises.
            notch.size
        }
    }

    /// Bottom corners of the folded slab. On a real notch they sit inside the
    /// cut-out and barely matter; on a drawn tab they are the whole reason it
    /// reads as a notch rather than a black bar.
    public var collapsedBottomRadius: CGFloat {
        switch style {
        case .physical: 8
        case .synthetic: (notch.height * 0.62).rounded()
        }
    }

    /// Height of the row the anchor occupies once the panel is open — content
    /// lays out below it. On a physical notch that is the cut-out itself (content
    /// under it would be unreadable); a synthetic tab is ~12 pt tall — far too
    /// thin to lay a header against, hence the floor.
    public var topStripHeight: CGFloat { max(notch.height, 28) }

    // MARK: - Hit regions

    /// Pointer region that opens the panel — deliberately larger than the
    /// anchor. `NSRect.contains` **excludes the max edge**, and a pointer
    /// pressed against the top of the screen reports exactly that coordinate,
    /// so the anchor rect alone misses the one approach people actually use:
    /// sliding along the menu bar into the notch.
    public var trigger: CGRect {
        // Dictate's numbers, verbatim: the synthetic tab is thin enough that
        // hitting it exactly is a chore, so it gets 6 pt of room underneath.
        // The real notch needs none — it is tall.
        let slack: CGFloat = style == .physical ? 0 : 6
        return CGRect(
            x: notch.minX - 6,
            y: notch.minY - slack,
            width: notch.width + 12,
            height: notch.height + slack + 4)
    }

    /// What holds the panel open once it is. Same max-edge problem as `trigger`,
    /// and it bites harder here: the panel's top edge *is* the screen's top
    /// edge, so hit-testing the raw frame drops a pointer parked against the
    /// top — the panel folds, the trigger immediately catches the same pointer,
    /// and it flickers open and shut forever.
    public var hold: CGRect {
        CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height + 4)
    }

    /// How long the pointer must dwell before the panel opens. Dictate's single
    /// 150 ms: long enough that crossing the anchor on the way to a menu does
    /// not trigger it, short enough to feel immediate when meant. (Session 1's
    /// extra 100 ms for drawn tabs is gone with the mushroom that motivated it.)
    public var dwell: Duration { .milliseconds(150) }

    /// The anchor in panel-local coordinates, so the chrome can draw the
    /// cut-out in exactly the right place.
    public var notchInPanel: CGRect {
        CGRect(
            x: notch.minX - panel.minX,
            y: notch.minY - panel.minY,
            width: notch.width,
            height: notch.height)
    }
}
