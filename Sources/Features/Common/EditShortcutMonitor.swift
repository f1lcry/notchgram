import AppKit

/// LSUIElement apps have no main menu, so the standard editing shortcuts
/// (⌘C/⌘V/⌘X/⌘A/⌘Z) never reach text views through menu actions. This local key
/// monitor restores them.
///
/// **Mandatory, not a nicety.** Without it, paste into the composer silently
/// does nothing — which for a Telegram client means the single most common way
/// of sending a link or a snippet is broken with no error to explain it.
///
/// Ported verbatim from Dictate, including the physical key codes: on ЙЦУКЕН,
/// ⌘C reports `charactersIgnoringModifiers == "с"`, so a character-based monitor
/// stops working the moment the layout changes.
@MainActor
enum EditShortcutMonitor {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors always fire on the main thread.
            let consumed = MainActor.assumeIsolated {
                handle(event)
            }
            return consumed ? nil : event
        }
    }

    /// Physical key codes (kVK_ANSI_*), so shortcuts keep working on non-Latin
    /// layouts — on ЙЦУКЕН, ⌘C reports charactersIgnoringModifiers = "с".
    private enum Key {
        static let a: UInt16 = 0
        static let z: UInt16 = 6
        static let x: UInt16 = 7
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let q: UInt16 = 12
        static let w: UInt16 = 13
    }

    /// Returns true when the event was handled and should be swallowed.
    private static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command {
            let action: Selector?
            switch event.keyCode {
            case Key.c: action = #selector(NSText.copy(_:))
            case Key.v: action = #selector(NSText.paste(_:))
            case Key.x: action = #selector(NSText.cut(_:))
            case Key.a: action = #selector(NSText.selectAll(_:))
            case Key.z: action = Selector(("undo:"))
            // Deliberately no ⌘W: the panel is never "dismissed", only
            // collapsed by the hover state machine, and closing the window
            // would leave the app running with nothing on screen.
            case Key.q:
                NSApp.terminate(nil)
                return true
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) {
                return true
            }
        } else if flags == [.command, .shift], event.keyCode == Key.z {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) {
                return true
            }
        }
        return false
    }
}
