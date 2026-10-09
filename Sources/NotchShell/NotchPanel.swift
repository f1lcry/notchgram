import AppKit

/// The window every panel is built on.
///
/// Recipe is load-bearing, every line of it (D16/D17, plan §3.4):
///  - `.nonactivatingPanel` + `canBecomeKey = true` is what lets a click focus
///    the composer while `NSWorkspace.frontmostApplication` never changes.
///    **Never call `NSApp.activate()`**, and treat `NSApp.isActive` as
///    meaningless — it flips true while this panel is key. Use `isKeyWindow`.
///  - `hidesOnDeactivate = false`: `NSPanel` hides on app deactivation by
///    default, which for a background app means "always".
///  - `.statusBar` level puts the slab above the menu bar, which is the point:
///    the open panel is transient and may cover the bar's middle; folded, the
///    window is click-through and the bar is untouched.
///  - `.canJoinAllSpaces + .stationary + .fullScreenAuxiliary` keeps it present
///    across Spaces including fullscreen ones. That membership decays over a
///    session, so the controller re-asserts it periodically.
public final class NotchPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        hidesOnDeactivate = false
        isFloatingPanel = true
        // NOT `becomesKeyOnlyIfNeeded = true` (Dictate's flag, dropped in
        // Session 5): with it, AppKit resigns key on every click that lands
        // outside a text field — the window server's key focus snaps back to
        // the previously active app, and Esc/typing silently go there. The
        // feared "first click swallowed by key transfer" bug does not apply:
        // that swallowing belongs to window *activation*, which never happens
        // here (`.nonactivatingPanel` + `acceptsFirstMouse`), verified by
        // probe — a first click from another app opens the chat row under it.
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Excluded from ⌘-Tab / Mission Control window cycling.
        isExcludedFromWindowsMenu = true
    }

    /// What Esc does once there is no focus left to release — the app closes
    /// the open chat with it (Telegram's Esc), stepping back one level per
    /// press. The shell stays ignorant of what "back" means.
    public var cancelHandler: (() -> Void)?

    /// Reports a keystroke/click/scroll inside the panel to the hover state
    /// machine — the activity signal behind the focus-hold idle timeout.
    public var activityHandler: (() -> Void)?

    /// Esc steps back: first press releases first responder (leaves the
    /// composer/search), the next hands over to `cancelHandler` (closes the
    /// open chat). The panel itself is never "dismissed" — only collapsed by
    /// the hover state machine.
    public override func cancelOperation(_ sender: Any?) {
        if firstResponder !== self, firstResponder is NSText {
            makeFirstResponder(nil)
        } else {
            cancelHandler?()
        }
    }

    /// Clicking a text field in this panel did nothing — the founder's "search
    /// does not work". Two AppKit/SwiftUI gaps, both patched here, in the one
    /// place every click passes through (events dispatch straight to the
    /// deepest hit-tested view, so view-level overrides never see them):
    ///
    /// - `becomesKeyOnlyIfNeeded` never fires for SwiftUI's text fields — the
    ///   hosting view does not report `needsPanelToBecomeKey` — so the panel
    ///   stayed non-key and every keystroke went to whatever app *was* key.
    ///   Taking key on mouse-down does not swallow the click (that bug is
    ///   about window *activation*, which never happens here) and leaves the
    ///   frontmost app untouched — the panel is non-activating.
    /// - SwiftUI only moves focus into its `AppKitTextField` from a click
    ///   while the application is active; for a background agent it silently
    ///   refuses, verified by probe (window key, first responder unmoved). A
    ///   direct `makeFirstResponder` on the hit field works, so the panel does
    ///   AppKit's job itself. Dictate never met either gap: it has no text
    ///   input at all.
    public override func sendEvent(_ event: NSEvent) {
        // Esc is routed here, before dispatch: with a field editor focused the
        // normal path already ends in `cancelOperation` (release focus), but
        // with anything else as first responder the hosting view swallows the
        // key and "step back" never fires.
        if event.type == .keyDown, event.keyCode == 53, !(firstResponder is NSText) {
            cancelOperation(self)
            return
        }
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel:
            activityHandler?()
        default:
            break
        }
        if event.type == .leftMouseDown {
            if !isKeyWindow { makeKey() }
            // A click outside every editable field ends the editing session,
            // exactly like clicking a table row does in a normal AppKit
            // window. Without this, one click into search/composer focused a
            // field *forever* — no later row click released it, its focus hold
            // never lapsed, and the panel could not auto-close again (the
            // founder's organic "the window got stuck").
            if !focusHitTextField(at: event.locationInWindow),
               firstResponder !== self, firstResponder is NSText {
                makeFirstResponder(nil)
            }
        }
        super.sendEvent(event)
    }

    /// Hit-testing cannot find the field: SwiftUI's gesture layer answers
    /// `hitTest`, not the platform view it wraps. Instead, walk the tree for
    /// the deepest editable AppKit text view whose bounds contain the click.
    /// Returns whether the click landed on an editable field.
    @discardableResult
    private func focusHitTextField(at locationInWindow: NSPoint) -> Bool {
        guard let content = contentView else { return false }

        // Collect first, test containment only on the fields themselves:
        // SwiftUI's intermediate containers are routinely zero-sized with
        // children laid out beyond their bounds, so pruning the walk by
        // ancestor containment loses the field.
        var candidates: [NSView] = []
        func collect(_ view: NSView, depth: Int) {
            guard depth < 24, !view.isHidden else { return }
            if let field = view as? NSTextField, field.isEditable {
                candidates.append(field)
            } else if let text = view as? NSTextView, text.isEditable {
                candidates.append(text)
            }
            for sub in view.subviews { collect(sub, depth: depth + 1) }
        }
        collect(content, depth: 0)

        guard let target = candidates.first(where: { view in
            view.bounds
                .insetBy(dx: -4, dy: -4)
                .contains(view.convert(locationInWindow, from: nil))
        }) else { return false }
        if let field = target as? NSTextField {
            // Already editing this field: leave the field editor alone so the
            // click just moves the caret instead of restarting the session.
            let editing = (firstResponder as? NSTextView)?.delegate === field
            if !editing { makeFirstResponder(field) }
        } else if firstResponder !== target {
            makeFirstResponder(target)
        }
        return true
    }
}
