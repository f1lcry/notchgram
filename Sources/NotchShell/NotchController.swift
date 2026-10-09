import AppKit
import SwiftUI
import os

/// Runs the panel: one fixed-size non-activating window per display, and the
/// hover state machine that decides which of them is open.
///
/// Three things are deliberate, all three hard-won in Dictate.
///
/// **A window never changes frame.** A tracking area — or a hit test — against a
/// window that animates its own frame fires enter/exit on the moving edge, and
/// the panel ends up oscillating and sizing itself to the pointer. All motion is
/// a SwiftUI spring inside a window that stands still. A panel-size change is
/// therefore a full `rebuild()` while collapsed, never a `setFrame`.
///
/// **Hover is polled, never tracked** (D16). Tracking areas lose the pointer in
/// exactly the cases that matter: pressed against the top edge of the screen, or
/// already inside a view when that view starts accepting events — no
/// `mouseEntered`, therefore no `mouseExited`, therefore a stuck panel. SwiftUI's
/// `.onHover` is worse: it is scoped to the active application and simply does
/// not fire for a background agent. Polling a point against a rect has none of
/// those states, and one loop covers every screen.
///
/// **Coverage only hides the collapsed tab** (D22, Session-5 revision): over a
/// fullscreen window the drawn tab paints nothing, but the window stays
/// ordered in and the trigger keeps working — hover and force-expand summon
/// the panel over a fullscreen Space. Ordering the window out (Dictate's
/// model) or skipping covered hosts in the poll produced the "phantom": an
/// invisible panel whose display had a live trigger but nothing to show.
@MainActor
public final class NotchController {

    // MARK: - Timings
    //
    // Ported verbatim. Each of these is a fixed bug, not a preference.

    /// Long enough that crossing the notch on the way to a menu does not trigger
    /// it, short enough to feel immediate when meant. Per-geometry: a drawn tab
    /// overlaps the menu bar and needs 250 ms; a real notch needs 150.
    static let grace = Duration.milliseconds(250)
    /// Idle polling only has to beat the dwell; it doubles up while open.
    static let idlePoll = Duration.milliseconds(80)
    static let openPoll = Duration.milliseconds(40)
    /// Comfortably past the unfold spring.
    static let settleDelay = Duration.milliseconds(450)
    /// Past the *fold* spring. Dropping alpha — or unmounting content — while
    /// the slab is still shrinking cuts the animation short, the exact
    /// cheapness the never-hidden window exists to avoid.
    static let foldDelay = Duration.milliseconds(700)
    /// Poll ticks between housekeeping probes. Both cost a round trip to the
    /// window server and neither describes anything that changes at hover
    /// frequency — entering fullscreen is a second-long animation, a Space
    /// switch about half of one.
    static let housekeepingInterval = 8
    /// Clamshell fires `didChangeScreenParameters` several times inside a
    /// second. Coalescing on a trailing timer is the difference between one
    /// rebuild and the panel flashing three to five times.
    static let reconfigurationDebounce = Duration.milliseconds(220)

    public static let expandAnimation = Animation.spring(response: 0.38, dampingFraction: 0.86)

    // MARK: - Dependencies

    private let shared: PanelSharedState
    private let settings: PanelSettings
    private let screenProvider: any ScreenProvider
    private let content: (PanelState, NotchGeometry) -> AnyView
    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "NotchShell")

    // MARK: - State

    private(set) var hosts: [NotchHost] = []
    private var pollTask: Task<Void, Never>?
    private var reconfigurationTask: Task<Void, Never>?
    private var configuration: ScreenConfiguration?
    private var housekeepingCountdown = 0
    private var hasDrawnTab = false
    private var started = false

    /// Invoked when Esc lands on a panel with no focus left to release —
    /// the app decides what "back" means (NotchGram: close the open chat).
    public var onPanelCancel: (() -> Void)?

    /// The host held open by a DebugBridge force-expand — and nothing else.
    /// (Dictate's `latched`, reduced to its debug role.) Interaction holds
    /// live in `shared.activePins` and only ever *keep* an already-expanded
    /// panel open; they cannot summon one.
    private var debugHost: NotchHost?

    /// Focus holds are activity-scoped, not indefinite: a field keeps its
    /// focus when the user simply walks away, so without an expiry one click
    /// into search meant the panel never auto-closed again. Keystrokes,
    /// clicks, scrolls (via `NotchPanel.activityHandler`) and pointer
    /// presence all refresh this; `poll()` releases stale focus holds.
    private var lastActivity = Date()
    static let focusHoldTimeout: TimeInterval = 20
    static let focusHoldReasons: Set<PanelSharedState.PinReason> = [
        .composerFocus, .searchFocus, .authFocus,
    ]

    public init(
        shared: PanelSharedState,
        settings: PanelSettings,
        screenProvider: any ScreenProvider = LiveScreenProvider(),
        content: @escaping (PanelState, NotchGeometry) -> AnyView
    ) {
        self.shared = shared
        self.settings = settings
        self.screenProvider = screenProvider
        self.content = content
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconfiguration() }
        }

        // Space switches are a workspace notification, not an application one.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }

        rebuild(force: true)
    }

    public func stop() {
        teardown()
        started = false
    }

    /// Coalesces the burst. A snapshot identical to the current one is not a
    /// reconfiguration at all — macOS also emits this notification for
    /// wallpaper and colour-profile changes.
    private func scheduleReconfiguration() {
        reconfigurationTask?.cancel()
        reconfigurationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconfigurationDebounce)
            guard !Task.isCancelled, let self else { return }
            self.rebuild(force: false)
        }
    }

    /// Rebuilt wholesale on dock/undock, display rearrangement, lid changes and
    /// panel-size changes: a monitor may have arrived or left, and the built-in
    /// notch may have moved to a different frame or gone away entirely.
    public func rebuild(force: Bool = true) {
        let screens = screenProvider.screens()
        let snapshot = ScreenConfiguration(screens)
        if !force, snapshot == configuration {
            log.debug("screen parameters changed but the configuration is identical — no rebuild")
            return
        }
        configuration = snapshot

        teardown()

        let geometries = NotchGeometryEngine.geometries(
            for: screens, settings: settings.geometrySettings)
        hosts = geometries.map(makeHost)
        guard !hosts.isEmpty else { return }

        hasDrawnTab = hosts.contains { $0.geometry.style == .synthetic }
        refreshCoverage()
        startPolling()

        // Only a debug force survives a screen change: an agent driving the
        // panel headlessly must not lose it to a display hot-plug. Interaction
        // holds deliberately do not — their views were just torn down with the
        // panels, the drafts live in shared state, and Session 4's "relocate
        // the pin to whatever host is under the pointer" was itself a way to
        // latch the wrong panel open.
        if shared.isDebugForced {
            debugHost = hostUnderPointer() ?? hosts.first
            for host in hosts { evaluate(host) }
        }
        log.notice("rebuilt \(self.hosts.count, privacy: .public) panel(s)")
    }

    private func teardown() {
        pollTask?.cancel()
        pollTask = nil
        debugHost = nil
        hasDrawnTab = false
        housekeepingCountdown = 0
        for host in hosts {
            host.cancelPending()
            host.panel.orderOut(nil)
        }
        hosts = []
    }

    // MARK: - Window

    private func makeHost(_ geometry: NotchGeometry) -> NotchHost {
        let state = PanelState()
        // The window is exactly the panel — Dictate's model. All motion is the
        // slab growing inside it, clipped to the shape.
        let panel = NotchPanel(contentRect: geometry.window)
        panel.cancelHandler = { [weak self] in self?.onPanelCancel?() }
        panel.activityHandler = { [weak self] in self?.noteUserActivity() }
        // The slab is always dark, so the content has to be light whatever the
        // system appearance is — otherwise `Color.primary` renders black on
        // black for anyone running Light Mode.
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NotchHostingView(rootView: content(state, geometry))
        hosting.frame = CGRect(origin: .zero, size: geometry.window.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.setFrame(geometry.window, display: false)
        // A real cut-out needs no stand-in drawn into it. Folded, the slab is a
        // black rectangle inside a black hole — invisible, right up until a
        // Space switch, where the panel rides along with the desktops and the
        // rectangle slides out from behind the notch in full view.
        panel.alphaValue = geometry.style == .physical ? 0 : 1
        // Click-through while folded is what hands the menu bar back.
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        return NotchHost(geometry: geometry, panel: panel, hosting: hosting, state: state)
    }

    // MARK: - Hover state machine

    private var anyExpanded: Bool { hosts.contains { $0.state.expanded } }

    /// Which screen the pointer is on — the best guess for where to put a panel
    /// nobody hovered into (a hotkey, or DebugBridge).
    private func hostUnderPointer() -> NotchHost? {
        let mouse = NSEvent.mouseLocation
        return hosts.first { $0.geometry.screen.contains(mouse) }
    }

    public func host(forScreenUUID uuid: String) -> NotchHost? {
        hosts.first { $0.geometry.screenUUID == uuid }
    }

    /// Coverage first, always. The Space just switched to may be a fullscreen
    /// one, and rejoining it before asking would shove the drawn tab onto
    /// exactly the window it is supposed to stay out of the way of.
    private func housekeeping() {
        if hasDrawnTab { refreshCoverage() }
        rejoinActiveSpace()
    }

    /// `canJoinAllSpaces` is set once and does not keep holding. Over a session
    /// a panel quietly falls off individual desktops — a window created moments
    /// earlier with identical collection behaviour sits on all of them, so it is
    /// the membership decaying, not the flags being wrong. Re-ordering restores
    /// it, and ordering front alone is a no-op for a window that is merely
    /// parked on another desktop: it has to leave first.
    private func rejoinActiveSpace() {
        for host in hosts {
            guard !host.panel.isOnActiveSpace else { continue }
            host.panel.orderOut(nil)
            host.panel.orderFrontRegardless()
        }
    }

    /// Coverage only decides whether the **collapsed tab paints** (D22, revised
    /// in Session 5): over a fullscreen window the drawn tab goes invisible —
    /// but the window stays ordered in, the pointer keeps being tracked, and
    /// hover still expands the panel. NotchGram's contract is "summonable over
    /// a fullscreen Space", which is stronger than Dictate's get-out-of-the-way
    /// HUD; Session 5's brief order-out port meant that a display the probe
    /// read as covered had a working trigger zone and an invisible,
    /// unopenable-looking panel — the founder's "phantom window".
    private func refreshCoverage() {
        let drawn = hosts.filter { $0.geometry.style == .synthetic }
        guard !drawn.isEmpty else { return }
        let covered = FullScreenProbe.coveredDisplays(among: drawn.map(\.geometry.screen))

        for host in drawn {
            let isCovered = covered.contains(host.geometry.screen)
            guard isCovered != host.state.isCovered else { continue }
            host.state.isCovered = isCovered
            // The tab hides or returns; an *expanded* panel is left entirely
            // alone — the pointer, not the probe, decides when it folds.
            if !host.state.expanded {
                host.panel.alphaValue = isCovered ? 0 : 1
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let open = self?.anyExpanded ?? false
                try? await Task.sleep(for: open ? Self.openPoll : Self.idlePoll)
                guard !Task.isCancelled, let self, !self.hosts.isEmpty else { return }
                self.poll()
            }
        }
    }

    private func poll() {
        housekeepingCountdown -= 1
        if housekeepingCountdown <= 0 {
            housekeepingCountdown = Self.housekeepingInterval
            housekeeping()
        }

        let mouse = NSEvent.mouseLocation
        // Covered hosts track too: coverage hides the tab, not the trigger.
        // Skipping them is what made hover die whenever the probe (rightly or
        // wrongly) read a display as fullscreen-covered.
        for host in hosts {
            let geometry = host.geometry
            // Open, the whole panel holds it — that margin is the grace zone.
            // Both rects overhang the top of the screen on purpose.
            let inside = host.state.expanded
                ? geometry.hold.contains(mouse)
                : geometry.trigger.contains(mouse)
            if inside != host.state.pointerInside {
                host.state.pointerInside = inside
                evaluate(host)
            }
        }
        if hosts.contains(where: { $0.state.pointerInside }) {
            lastActivity = Date()
        }
        expireStaleFocusHolds()
    }

    /// A panel held open purely by field focus, with the pointer elsewhere and
    /// no input for `focusHoldTimeout`, is abandoned — release the hold and
    /// the responder so it can fold. Uploads and open file dialogs
    /// (`pendingOutgoing`, `filePicker`) are real work and never expire.
    private func expireStaleFocusHolds() {
        guard !shared.activePins.isEmpty,
              shared.activePins.isSubset(of: Self.focusHoldReasons),
              !shared.isDebugForced,
              !hosts.contains(where: { $0.state.pointerInside }),
              Date().timeIntervalSince(lastActivity) > Self.focusHoldTimeout
        else { return }
        log.notice("releasing stale focus hold: \(self.shared.activePins.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)")
        // Dropping the responder lets SwiftUI's FocusState fire its own
        // falling edge; clearing the set as well covers an edge that never
        // lands (the view may already be gone).
        for host in hosts where host.state.expanded {
            host.panel.makeFirstResponder(nil)
        }
        shared.activePins.subtract(Self.focusHoldReasons)
        for host in hosts { evaluate(host) }
    }

    /// Any keystroke, click or scroll inside a panel window.
    func noteUserActivity() {
        lastActivity = Date()
    }

    private func evaluate(_ host: NotchHost) {
        host.expandTask?.cancel()
        host.expandTask = nil
        host.collapseTask?.cancel()
        host.collapseTask = nil

        // An interaction hold (composer focus, live upload, open file dialog)
        // keeps an expanded panel open; it never summons a collapsed one.
        let held = host.state.expanded && !shared.activePins.isEmpty
        let shouldOpen = host.state.pointerInside || debugHost === host || held
        if shouldOpen {
            guard !host.state.expanded else { return }
            host.expandTask = Task { [weak self, weak host] in
                try? await Task.sleep(for: host?.geometry.dwell ?? .milliseconds(150))
                guard !Task.isCancelled, let self, let host else { return }
                self.expand(host)
            }
        } else {
            guard host.state.expanded else { return }
            host.collapseTask = Task { [weak self, weak host] in
                try? await Task.sleep(for: Self.grace)
                guard !Task.isCancelled, let self, let host else { return }
                self.collapse(host)
            }
        }
    }

    private func expand(_ host: NotchHost) {
        guard !host.state.expanded else { return }

        // Exactly one panel is expanded at a time. Hovering another screen's
        // anchor moves the panel there rather than opening a second copy.
        for other in hosts where other !== host && other.state.expanded {
            collapse(other)
        }

        host.panel.ignoresMouseEvents = false
        // Before the spring, not with it: at this instant the slab is still
        // collapsed and therefore still inside the cut-out, so turning the panel
        // back on cannot flash.
        host.fadeTask?.cancel()
        host.fadeTask = nil
        host.mountTask?.cancel()
        host.mountTask = nil
        host.panel.alphaValue = 1
        host.state.mounted = true

        withAnimation(Self.expandAnimation) {
            host.state.expanded = true
        }

        host.settleTask?.cancel()
        host.settleTask = Task { [weak host] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let host, host.state.expanded else { return }
            host.state.settled = true
        }
    }

    private func collapse(_ host: NotchHost) {
        guard host.state.expanded else { return }
        host.state.settled = false
        withAnimation(Self.expandAnimation) {
            host.state.expanded = false
        }
        host.settleTask?.cancel()
        host.settleTask = nil
        // Hand the menu bar back immediately; the fold itself is just pixels.
        host.panel.ignoresMouseEvents = true

        // Unmount the content once the fold has finished — not before, or the
        // animation is cut short, and not never, or a live chat list keeps
        // rendering for a panel nobody has open.
        host.mountTask?.cancel()
        host.mountTask = Task { [weak host] in
            try? await Task.sleep(for: Self.foldDelay)
            guard !Task.isCancelled, let host, !host.state.expanded else { return }
            host.state.mounted = false
        }

        // And a panel over a real cut-out — or one hidden under a fullscreen
        // window — goes back to painting nothing at all.
        guard host.geometry.style == .physical || host.state.isCovered else { return }
        host.fadeTask = Task { [weak host] in
            try? await Task.sleep(for: Self.foldDelay)
            guard !Task.isCancelled, let host, !host.state.expanded else { return }
            host.panel.alphaValue = 0
        }
    }

    // MARK: - Programmatic control (DebugBridge, hotkeys)

    /// Pins a panel open regardless of the pointer, and waits for the unfold to
    /// settle so a caller never races the spring.
    public func forceExpand(screenUUID: String? = nil) async {
        guard let host = screenUUID.flatMap(host(forScreenUUID:))
            ?? hostUnderPointer()
            ?? hosts.first
        else { return }

        shared.isDebugForced = true
        debugHost = host
        // Coverage never blocks an expand (D22) — it only hides the collapsed
        // tab — so there is nothing to reset here.
        host.panel.orderFrontRegardless()
        expand(host)
        try? await Task.sleep(for: Self.settleDelay + .milliseconds(50))
    }

    public func forceCollapse() async {
        shared.isDebugForced = false
        debugHost = nil
        // The bridge's `collapse` doubles as the universal unstick: whatever
        // reason might have leaked, this clears it.
        shared.activePins.removeAll()
        for host in hosts { collapse(host) }
        try? await Task.sleep(for: Self.foldDelay + .milliseconds(50))
        refreshCoverage()
    }

    /// Raises or clears one hold reason. Holds keep the expanded panel open
    /// while the pointer is elsewhere — typing with the pointer parked outside
    /// the panel must not collapse it mid-sentence, and a file mid-upload must
    /// not fold away. Each reason has exactly one owning surface (see
    /// `PanelSharedState.PinReason`).
    public func setPin(_ reason: PanelSharedState.PinReason, _ active: Bool) {
        guard shared.activePins.contains(reason) != active else { return }
        if active {
            shared.activePins.insert(reason)
        } else {
            shared.activePins.remove(reason)
        }
        for candidate in hosts { evaluate(candidate) }
    }

    /// A size change is a rebuild, never a `setFrame` — see the type comment.
    public func applyPanelSize(_ size: CGSize) {
        settings.panelSize = size
        rebuild(force: true)
    }

    public func setForceSynthetic(_ enabled: Bool) {
        settings.forceSynthetic = enabled
        rebuild(force: true)
    }
}

/// One screen's worth of panel: its anchor, its window, and the hover
/// bookkeeping that belongs to it alone.
@MainActor
public final class NotchHost {
    public let geometry: NotchGeometry
    public let panel: NotchPanel
    let hosting: NotchHostingView
    public let state: PanelState

    var expandTask: Task<Void, Never>?
    var collapseTask: Task<Void, Never>?
    var settleTask: Task<Void, Never>?
    /// Waits out the fold before the panel stops painting.
    var fadeTask: Task<Void, Never>?
    /// Waits out the fold before the content tree is unmounted.
    var mountTask: Task<Void, Never>?

    init(geometry: NotchGeometry, panel: NotchPanel, hosting: NotchHostingView, state: PanelState) {
        self.geometry = geometry
        self.panel = panel
        self.hosting = hosting
        self.state = state
    }

    func cancelPending() {
        for task in [expandTask, collapseTask, settleTask, fadeTask, mountTask] {
            task?.cancel()
        }
        expandTask = nil
        collapseTask = nil
        settleTask = nil
        fadeTask = nil
        mountTask = nil
    }
}

/// Hosting view for the slab. The window is exactly the panel (no transparent
/// margins to carve out of the hit region any more), so the only job left here
/// is first-click behaviour.
final class NotchHostingView: NSHostingView<AnyView> {
    /// First click from another application lands on the control under the
    /// pointer instead of being spent on window activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every click in the panel takes — and keeps — key status. Without this,
    /// `becomesKeyOnlyIfNeeded` treats a click on anything that is not a text
    /// field as not needing key and actively resigns it (AppKit-local re-takes
    /// after the fact do not move the window server's key focus, so keyboard
    /// events — Esc included — kept going to the previously active app). The
    /// panel is non-activating, so the frontmost application is untouched.
    override var needsPanelToBecomeKey: Bool { true }
}
