import Foundation

/// How this process was launched: against the real account, or in demo mode.
///
/// Demo mode (`NOTCHGRAM_DEMO=1`) exists **only in Debug builds** — a Release
/// build reads the variable as nothing. It renders the real UI over fictional
/// fixture content (see `DemoContent`) for README screenshots and the docs GIF,
/// and it is built so it cannot touch anything that belongs to a real account:
///
/// - no TDLib client is ever created (so no database, no network);
/// - no Keychain access (the database key is only read by a client);
/// - preferences live in their own suite, never the app's real domain;
/// - the account registry points at a throwaway directory.
enum LaunchMode {
    static let isDemo: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["NOTCHGRAM_DEMO"] == "1"
        #else
        false
        #endif
    }()

    /// The preference store the panel settings persist to.
    static var preferences: UserDefaults {
        #if DEBUG
        if isDemo, let demo = UserDefaults(suiteName: demoSuiteName) { return demo }
        #endif
        return .standard
    }

    @MainActor
    static func makeRegistry() -> AccountRegistry {
        #if DEBUG
        if isDemo {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotchGramDemo/accounts")
            return AccountRegistry(defaults: preferences, root: root)
        }
        #endif
        return AccountRegistry()
    }

    #if DEBUG
    static let demoSuiteName = "com.f1lcry.notchgram.demo"

    /// Runs first thing in `main()`, before anything reads a preference.
    ///
    /// The demo suite is wiped so every demo launch starts from defaults (the
    /// default panel size, no forced synthetic notch). The UI language is
    /// pinned to English through the *argument* domain: it is volatile, so the
    /// real `AppLanguage` preference is overridden for this process only and
    /// never written. It has to happen before `L10n.isRussian` — a lazily
    /// initialised `static let` — is first read.
    static func prepareProcess() {
        guard isDemo else { return }
        UserDefaults.standard.removePersistentDomain(forName: demoSuiteName)
        let standard = UserDefaults.standard
        var arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppLanguage"] = "en"
        standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    #endif
}
