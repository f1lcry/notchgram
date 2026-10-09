import AppKit

/// Two-finger horizontal swipe over the conversation closes it — Telegram's
/// swipe-back, on a Magic Mouse or a trackpad.
///
/// Built on `scrollWheel` phases rather than `NSEvent` swipe events: swipe
/// events only exist while the "Swipe between pages" system gesture is
/// enabled, but phased scroll deltas are always delivered. A gesture counts as
/// a swipe when its horizontal travel clears a threshold while staying
/// dominant over the vertical — the message list scrolls only vertically, so a
/// dominant horizontal drag over it is never ambiguous. Wheel mice send no
/// phases and are deliberately ignored.
@MainActor
enum SwipeBackMonitor {
    private static var installed = false
    private static var isTracking = false
    private static var hasFired = false
    private static var accumulatedX: CGFloat = 0
    private static var accumulatedY: CGFloat = 0

    /// Horizontal travel (pt) that commits the gesture.
    static let distance: CGFloat = 60

    /// `isEligible` is asked once per gesture, at its first touch: whether the
    /// event begins over UI that swipe-back applies to.
    static func install(
        isEligible: @escaping (NSEvent) -> Bool,
        onBack: @escaping () -> Void
    ) {
        guard !installed else { return }
        installed = true

        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let consumed = MainActor.assumeIsolated {
                handle(event, isEligible: isEligible, onBack: onBack)
            }
            return consumed ? nil : event
        }
    }

    /// Returns true when the event belongs to a fired gesture and must not
    /// also scroll whatever ends up under the pointer.
    private static func handle(
        _ event: NSEvent,
        isEligible: (NSEvent) -> Bool,
        onBack: () -> Void
    ) -> Bool {
        guard event.momentumPhase.isEmpty else { return false }

        switch event.phase {
        case .began:
            isTracking = isEligible(event)
            hasFired = false
            accumulatedX = 0
            accumulatedY = 0
            return false
        case .changed:
            guard isTracking else { return false }
            if hasFired { return true }
            accumulatedX += event.scrollingDeltaX
            accumulatedY += event.scrollingDeltaY
            if abs(accumulatedX) > Self.distance,
               abs(accumulatedX) > 2 * abs(accumulatedY) {
                hasFired = true
                onBack()
                return true
            }
            return false
        case .ended, .cancelled:
            let fired = hasFired
            isTracking = false
            hasFired = false
            return fired
        default:
            return false
        }
    }
}
