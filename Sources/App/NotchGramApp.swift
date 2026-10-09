import AppKit

/// Entry point. AppKit lifecycle (not SwiftUI `App`) because the whole UI lives
/// in a borderless `NSPanel` we own outright — there is no main window, no Dock
/// icon and no menu bar (D2, `LSUIElement`).
@main
enum NotchGramApp {
    /// `NSApplication.delegate` is unowned. Without a strong reference of our
    /// own the delegate would be deallocated the moment `main()`'s frame ends.
    @MainActor private static var strongDelegate: AppDelegate?

    @MainActor
    static func main() {
        #if DEBUG
        LaunchMode.prepareProcess()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        strongDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
