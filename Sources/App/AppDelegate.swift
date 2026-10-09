import AppKit
import SwiftUI
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unit tests are hosted by this app, so `main()` runs before the test
    /// bundle loads. Spawning desktop panels — or a TDLib client that would open
    /// the founder's real database — from a test run is both slow and dangerous.
    /// Ported verbatim from Dictate.
    static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "App")

    /// Demo mode keeps its own preference suite and a throwaway account root,
    /// so it can never read or write the real account's state.
    private let registry = LaunchMode.makeRegistry()
    private let shared = PanelSharedState()
    private let settings = PanelSettings(defaults: LaunchMode.preferences)
    #if DEBUG
    // The agent control channel exists in Debug builds only (D43).
    private let router = DebugRouter()
    private lazy var bridge = DebugServer(router: router)
    #endif

    private let chatRepo = ChatRepo()
    private let messageRepo = MessageRepo()
    private let fileStore = FileStore()
    private let folders = ChatFolders()
    private let search = ChatSearch()
    private let mediaViewer = MediaViewerState()
    private let loginItem = LoginItem()
    private lazy var notifier = MessageNotifier(chatRepo: chatRepo, shared: shared)
    private var session: TelegramSession?
    private var controller: NotchController?
    private var tdlibVersion: String?
    private var tdlibError: String?
    private var isTerminating = false
    private var hasClosedTelegram = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        // LSUIElement apps have no main menu, so ⌘C/⌘V/⌘X/⌘A never reach text
        // views. Without this, paste into a code field or the composer silently
        // does nothing — with no error to explain it.
        EditShortcutMonitor.install()

        if LaunchMode.isDemo {
            // No TDLib probe, no client, no notifications: demo mode must not
            // touch the TDLib data directory, the Keychain or the network.
            startDemo()
        } else {
            probeTDLib()
            startTelegram()
        }
        startPanels()

        #if DEBUG
        router.delegate = self
        if DebugServer.isEnabled {
            bridge.start()
        } else {
            log.notice("DebugBridge disabled (set DebugBridgeEnabled or NOTCHGRAM_DEBUG_BRIDGE=1)")
        }
        #endif

        // After the test guard above on purpose: a unit-test host must never
        // check for — let alone install — an update.
        AppUpdater.shared.start()

        if !LaunchMode.isDemo { requestNotificationAuthorization() }
    }

    /// `NOTCHGRAM_DEMO=1` (Debug builds only): the real UI over fictional
    /// fixture content. The session never starts a client; the repos are fed
    /// through `injectUpdate`, the same sink path real updates take.
    private func startDemo() {
        #if DEBUG
        let session = TelegramSession(
            account: DemoContent.account,
            registry: registry,
            applicationVersion: "NotchGram demo")
        self.session = session
        session.attachRepos(
            chat: chatRepo, messages: messageRepo, files: fileStore, folders: folders)
        DemoContent.install(session: session, messageRepo: messageRepo)
        log.notice("demo mode: fixture content, no TDLib client")
        #endif
    }

    /// TDLib holds an encrypted SQLite database open, so termination has to
    /// close it before the process goes away — and that close is async.
    ///
    /// **Not `.terminateLater`.** That reply parks AppKit in a nested wait loop
    /// which does not service Swift Concurrency's main-actor executor: the
    /// shutdown task never resumes, the watchdog task never fires either, and
    /// the app hangs forever with no way out but `kill -9` — exactly the database
    /// corruption D20 exists to prevent. Measured, not theorised: with
    /// `.terminateLater` the process was still alive 25 s after `quit` with
    /// neither task having run a single line.
    ///
    /// `.terminateCancel` returns control to the normal run loop, so the main
    /// actor keeps being serviced. The task then re-issues `NSApp.terminate` and
    /// the second pass short-circuits to `.terminateNow`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hasClosedTelegram { return .terminateNow }
        guard !isTerminating else { return .terminateCancel }
        isTerminating = true

        Task { @MainActor in
            log.notice("shutdown: closing Telegram session")
            await session?.shutdown()
            log.notice("shutdown: session closed")
            controller?.stop()
            #if DEBUG
            bridge.stop()
            #endif
            hasClosedTelegram = true
            NSApp.terminate(nil)
        }
        // `TDClient.shutdown` is itself bounded at 5 s; this covers the case
        // where something above it hangs anyway.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !hasClosedTelegram else { return }
            log.error("shutdown watchdog fired — terminating without a clean close")
            hasClosedTelegram = true
            NSApp.terminate(nil)
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Startup

    /// Requested in M0 on purpose: CP1 is delivered *by* a user notification,
    /// and the authorization prompt would otherwise be an unbudgeted fourth
    /// founder touch that silently swallows the ping.
    private func requestNotificationAuthorization() {
        // The delegate has to be in place before the request, and before the
        // app finishes launching — it is also what lets a banner click route
        // back into the panel (M9).
        UNUserNotificationCenter.current().delegate = self
        // Asked a beat after launch rather than inside
        // `applicationDidFinishLaunching`: an agent that requests authorization
        // before its run loop is up can be refused outright.
        Task { @MainActor [log] in
            try? await Task.sleep(for: .seconds(2))
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            log.notice("UN settings before request: \(settings.authorizationStatus.rawValue, privacy: .public)")
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                log.notice("UN authorization granted=\(granted, privacy: .public)")
            } catch {
                log.error("UN authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Synchronous: `version` and `commit_hash` are the two options TDLib
    /// answers through `td_execute` before any client exists, so this needs no
    /// client and leaks none.
    private func probeTDLib() {
        if let version = TDLibProbe.version() {
            tdlibVersion = version
            log.notice("TDLib \(version, privacy: .public) (\(TDLibProbe.commitHash() ?? "?", privacy: .public))")
        } else {
            tdlibError = "getOption(version) returned nothing"
            log.error("TDLib probe failed")
        }
    }

    private func startTelegram() {
        let account = registry.ensureDefaultAccount()
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let session = TelegramSession(
            account: account, registry: registry, applicationVersion: "NotchGram \(version)")
        self.session = session
        session.start()
        session.attachRepos(
            chat: chatRepo, messages: messageRepo, files: fileStore, folders: folders)
        session.addSink(notifier)
        if let client = session.client { search.attach(client: client, repo: chatRepo) }
    }

    private func startPanels() {
        guard let session else { return }
        let shared = self.shared
        let chatRepo = self.chatRepo
        let messageRepo = self.messageRepo
        let fileStore = self.fileStore
        let folders = self.folders
        let search = self.search
        let settings = self.settings
        let loginItem = self.loginItem
        let mediaViewer = self.mediaViewer
        let controller = NotchController(shared: shared, settings: settings) {
            [weak self] state, geometry in
            let chrome = AnyView(
                NotchChromeView(
                    state: state,
                    geometry: geometry,
                    expandedFill: Theme.Palette.panelShell
                ) {
                    PanelRootView(
                        session: session,
                        chatRepo: chatRepo,
                        messageRepo: messageRepo,
                        fileStore: fileStore,
                        folders: folders,
                        search: search,
                        settings: settings,
                        loginItem: loginItem,
                        onPanelSizeChange: { size in
                            self?.controller?.applyPanelSize(size)
                        },
                        shared: shared,
                        panelState: state,
                        geometry: geometry,
                        mediaViewer: mediaViewer,
                        setPin: { reason, active in
                            self?.controller?.setPin(reason, active)
                        })
                }
            )
            #if DEBUG
            if LaunchMode.isDemo {
                return AnyView(DemoStageView(geometry: geometry) { chrome })
            }
            #endif
            return chrome
        }
        self.controller = controller
        controller.start()

        // Esc steps back one level per press (the panel already spent the
        // first press releasing keyboard focus, if there was any). The media
        // viewer is the innermost level.
        controller.onPanelCancel = { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                if self.mediaViewer.isPresented {
                    self.mediaViewer.close()
                } else if self.shared.activePane != .conversation {
                    self.shared.activePane = .conversation
                } else if self.shared.openChatId != nil {
                    self.shared.openChatId = nil
                }
            }
        }

        // Telegram's swipe-back: a horizontal two-finger swipe over the
        // conversation pane closes the open chat.
        SwipeBackMonitor.install(
            isEligible: { [weak self] event in
                guard let self,
                      event.window is NotchPanel,
                      // Not through the media viewer: a swipe there must not
                      // close the chat underneath it.
                      !self.mediaViewer.isPresented,
                      self.shared.activePane == .conversation,
                      self.shared.openChatId != nil
                else { return false }
                return event.locationInWindow.x
                    > Theme.Metrics.chatListWidth + Theme.Metrics.contentPadding
            },
            onBack: { [weak self] in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    self.shared.openChatId = nil
                }
            })
    }
}

// MARK: - DebugBridge

#if DEBUG
extension AppDelegate: DebugBridgeDelegate {
    func debugStatus() -> DebugStatus {
        let bundle = Bundle.main
        let expanded = controller?.hosts.first { $0.state.expanded }
        let reference = expanded ?? controller?.hosts.first

        return DebugStatus(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            pid: ProcessInfo.processInfo.processIdentifier,
            configuration: Self.configuration,
            demo: LaunchMode.isDemo,
            tdlibVersion: tdlibVersion,
            authState: session?.authState.name ?? "noSession",
            connectionState: session?.connectionState.rawValue ?? "noSession",
            activeAccountId: session?.account.id,
            openChatId: shared.openChatId,
            windowNumber: reference?.panel.windowNumber ?? 0,
            panelState: expanded == nil ? "collapsed" : "expanded",
            focusedField: (reference?.panel.isKeyWindow == true)
                ? reference?.panel.firstResponder.map { String(describing: type(of: $0)) }
                : nil,
            focusedFieldText: search.isActive ? search.query : nil,
            frontmostApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            isKeyWindow: reference?.panel.isKeyWindow ?? false,
            activePins: shared.activePins.map(\.rawValue).sorted(),
            isDebugForced: shared.isDebugForced,
            panels: debugPanelStatuses(),
            screens: NSScreen.screens.count,
            loginItem: String(describing: loginItem.state),
            error: tdlibError ?? session?.lastError?.errorDescription)
    }

    func debugPerform(_ command: DebugCommandRequest) async throws -> DebugStatus {
        guard let controller else { throw DebugRouterError.notReady("panels") }

        switch command.command {
        case "expand":
            await controller.forceExpand(screenUUID: command.screen)

        case "collapse":
            await controller.forceCollapse()

        case "setSize":
            guard let width = command.width, let height = command.height else {
                throw DebugRouterError.missingArgument("width and height")
            }
            // A size change is a full rebuild while collapsed, never a
            // `setFrame`: the window that owns the hover target must not move.
            controller.applyPanelSize(CGSize(width: width, height: height))
            try? await Task.sleep(for: .milliseconds(150))

        case "forceSynthetic":
            controller.setForceSynthetic(command.enabled ?? true)
            try? await Task.sleep(for: .milliseconds(150))

        case "rebuild":
            controller.rebuild(force: true)
            try? await Task.sleep(for: .milliseconds(150))

        case "gotoAuthState":
            guard let name = command.state else {
                throw DebugRouterError.missingArgument("state")
            }
            guard let session else { throw DebugRouterError.notReady("session") }
            session.debugAuthStateOverride = name == "live"
                ? nil
                : try DebugAuthStates.state(named: name)
            try? await Task.sleep(for: .milliseconds(120))

        case "injectFixture":
            guard let name = command.state ?? command.path else {
                throw DebugRouterError.missingArgument("state (fixture name)")
            }
            guard let session else { throw DebugRouterError.notReady("session") }
            for update in try DebugFixtureScenarios.updates(named: name) {
                session.injectUpdate(update)
            }
            try? await Task.sleep(for: .milliseconds(150))

        // Every UI state a human can reach must be reachable here too — the
        // panes are behind buttons, so they need a command.
        case "setLoginItem":
            loginItem.setEnabled(command.enabled ?? true)
            try? await Task.sleep(for: .milliseconds(500))

        case "setPane":
            guard let name = command.state,
                  let pane = PanelSharedState.Pane(rawValue: name)
            else {
                throw DebugRouterError.missingArgument("state: conversation | settings | profile")
            }
            shared.activePane = pane
            try? await Task.sleep(for: .milliseconds(120))

        case "openChat":
            guard let chatId = command.chatId else {
                throw DebugRouterError.missingArgument("chatId")
            }
            shared.openChatId = chatId

        // Real-data testing: open the Nth row of the live chat list without
        // knowing its id, and pull history pages without a physical scroll.
        case "openChatAt":
            let index = Int(command.chatId ?? 0)
            guard chatRepo.chats.indices.contains(index) else {
                throw DebugRouterError.missingArgument("chatId (row index in range)")
            }
            shared.openChatId = chatRepo.chats[index].id
            shared.activePane = .conversation
            try? await Task.sleep(for: .milliseconds(400))

        // Diagnostic: walk the hosting view for AppKit text machinery and try
        // to focus the first editable field directly.
        case "focusSearch":
            guard let host = controller.hosts.first(where: { $0.state.expanded })
                ?? controller.hosts.first
            else { throw DebugRouterError.notReady("panels") }
            var classes: [String] = []
            var firstField: NSTextField?
            func walk(_ view: NSView, depth: Int) {
                if depth > 12 { return }
                let name = String(describing: type(of: view))
                if view is NSTextField || view is NSTextView || name.lowercased().contains("text") {
                    classes.append(name)
                }
                if firstField == nil, let field = view as? NSTextField, field.isEditable {
                    firstField = field
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            walk(host.hosting, depth: 0)
            host.panel.makeKey()
            if let field = firstField {
                host.panel.makeFirstResponder(field)
            }
            var status = debugStatus()
            status.error = "textish views: \(classes.joined(separator: ", "))"
            return status

        // Drive search exactly as typing does: set the query, wait out the
        // debounce and the network passes.
        case "search":
            search.query = command.state ?? ""
            try? await Task.sleep(for: .milliseconds(1200))

        case "selectFolder":
            // `chatId` doubles as the folder id; omit it for the main list.
            folders.selectedFolderId = command.chatId.map(Int.init)
            if let folderId = folders.selectedFolderId {
                await folders.loadFolder(folderId)
            }
            try? await Task.sleep(for: .milliseconds(400))

        case "loadOlder":
            let rounds = command.width.map(Int.init) ?? 1
            for _ in 0..<max(1, rounds) {
                await messageRepo.loadOlder()
                try? await Task.sleep(for: .milliseconds(350))
            }

        case "screenshot":
            guard let path = command.path else {
                throw DebugRouterError.missingArgument("path")
            }
            try capturePanel(to: URL(fileURLWithPath: path), screenUUID: command.screen)

        // The in-panel viewer is behind a click on a photo, so it needs a
        // command. `chatId` doubles as the message id; omitted, the newest
        // photo/video in the open conversation.
        case "openMedia":
            let target = command.chatId ?? messageRepo.items.last(where: {
                if case .messagePhoto = $0.content { return true }
                if case .messageVideo = $0.content { return true }
                return false
            })?.messageId
            guard let target else { throw DebugRouterError.notReady("no media in the open chat") }
            withAnimation(.easeOut(duration: 0.16)) {
                mediaViewer.present(items: messageRepo.items, at: target)
            }
            try? await Task.sleep(for: .milliseconds(350))

        // Demo only: paint a generated wallpaper + menu-bar band behind the
        // slab inside the panel window, so a window-scoped recording shows
        // the unfold against something other than black.
        case "setBackdrop":
            guard LaunchMode.isDemo else { throw DebugRouterError.notReady("demo mode") }
            DemoStage.shared.showsBackdrop = command.enabled ?? true
            try? await Task.sleep(for: .milliseconds(150))

        case "closeMedia":
            withAnimation(.easeOut(duration: 0.16)) { mediaViewer.close() }
            try? await Task.sleep(for: .milliseconds(250))

        case "quit":
            // Answer before tearing down, or the caller sees a dropped socket
            // and cannot tell a clean quit from a crash.
            let status = debugStatus()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                NSApp.terminate(nil)
            }
            return status

        default:
            throw DebugRouterError.unknownCommand(command.command)
        }
        return debugStatus()
    }

    /// In-app capture: needs no Screen Recording grant and works even when the
    /// panel is occluded, which is why `make screenshot` falls back to it.
    private func panelHost(screenUUID: String?) -> NotchHost? {
        screenUUID.flatMap { controller?.host(forScreenUUID: $0) }
            ?? controller?.hosts.first { $0.state.expanded }
            ?? controller?.hosts.first
    }

    private func capturePanel(to url: URL, screenUUID: String?) throws {
        guard let host = panelHost(screenUUID: screenUUID), let view = host.panel.contentView else {
            throw CocoaError(.fileNoSuchFile)
        }
        // The window is exactly the panel (no shadow margins since Session 5),
        // so the capture is simply the whole content view.
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func debugPanelStatuses() -> [DebugPanelStatus] {
        (controller?.hosts ?? []).map { host in
            let geometry = host.geometry
            return DebugPanelStatus(
                screenUUID: geometry.screenUUID,
                screenFrame: geometry.screen.asDebugArray,
                visibleFrame: geometry.visibleFrame.asDebugArray,
                isPhysicalNotch: geometry.style == .physical,
                notchRect: geometry.notch.asDebugArray,
                triggerRect: geometry.trigger.asDebugArray,
                panelSize: [geometry.panel.width, geometry.panel.height],
                state: host.state.expanded
                    ? (host.state.settled ? "expanded" : "expanding")
                    : (host.state.mounted ? "collapsing" : "collapsed"),
                windowNumber: host.panel.windowNumber,
                alpha: host.panel.alphaValue,
                isCovered: host.state.isCovered,
                ignoresMouseEvents: host.panel.ignoresMouseEvents,
                isKeyWindow: host.panel.isKeyWindow)
        }
    }

    // Only ever compiled in Debug now (D43), but kept honest in case the
    // surrounding gate moves.
    private static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
}
#endif

// MARK: - Notifications

/// `@preconcurrency` because `UNUserNotificationCenterDelegate` is not
/// annotated for Swift 6: its parameters (`UNNotification`,
/// `UNNotificationResponse`) are non-Sendable ObjC classes that UserNotifications
/// nonetheless hands to a main-thread delegate. This is one of the spots CLAUDE.md
/// means by "@preconcurrency only where a dependency forces it".
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// A background agent has no window to bring forward, so a notification
    /// arriving while NotchGram is "active" must still be shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a banner opens the chat it came from.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let chatId = info["chatId"] as? Int64 {
            shared.openChatId = chatId
            await controller?.forceExpand()
        }
    }
}

#if DEBUG
private extension CGRect {
    /// Geometry travels to the harness as `[x, y, w, h]`, so assertions are a
    /// diff rather than a screenshot squint.
    var asDebugArray: [Double] { [minX, minY, width, height] }
}
#endif
