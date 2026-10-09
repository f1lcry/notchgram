import AppKit
import Observation
import Sparkle

/// Sparkle 2 auto-update (D43).
///
/// The feed URL, the EdDSA public key and "automatic checks on" are Info.plist
/// keys generated from `project.yml`; this type only owns the updater's
/// lifetime and the two things Settings exposes (check now, check
/// automatically).
///
/// **Release builds only.** A Debug build pointed at the public feed would
/// offer to replace itself with the published release — and agents launch
/// Debug builds all day. `start()` is therefore a no-op in Debug, and it is
/// called after `AppDelegate`'s test-host guard, so a unit-test run never
/// constructs an updater either. `shared` itself is inert until `start()`.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// False in Debug builds and before `start()`; Settings disables its
    /// controls instead of offering a button that does nothing.
    private(set) var isAvailable = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override private init() {
        super.init()
    }

    func start() {
        #if !DEBUG
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        isAvailable = true
        #endif
    }

    /// Mirrors Sparkle's own persisted preference (`SUEnableAutomaticChecks`
    /// in user defaults), so there is exactly one source of truth.
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// "Check for Updates…". The panel is a non-activating window, so without
    /// activating first Sparkle's dialog can open behind whatever app is
    /// frontmost — and look like nothing happened.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

// NotchGram is an `LSUIElement` agent: no Dock icon, no main menu. Sparkle
// asks such apps to opt into "gentle reminders" so a *scheduled* update alert
// is not left sitting behind other windows where nobody sees it.
extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        // Sparkle calls its user-driver delegate on the main thread.
        MainActor.assumeIsolated {
            NSApp.activate()
        }
    }
}
