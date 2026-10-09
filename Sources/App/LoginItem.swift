import Foundation
import Observation
import ServiceManagement
import os

/// Launch at login, through `SMAppService.mainApp`.
///
/// Two things make this less trivial than the one-line API suggests:
///
/// 1. **Registration binds to the app's path and code signature.** It therefore
///    has to be exercised against the `/Applications` copy — which under D11 is
///    the Developer ID Release build — and re-signing with a different identity
///    invalidates it. That is the reason the signing split is fixed rather than
///    convenient.
/// 2. **`.requiresApproval` is a real state, not an error.** macOS may accept
///    the registration and still leave it off until the user approves it in
///    System Settings; reporting that honestly is the difference between "it
///    didn't work" and "one switch away".
@MainActor
@Observable
public final class LoginItem {
    public enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unknown
        case failed(String)

        public var isOn: Bool { self == .enabled }

        public var explanation: String? {
            switch self {
            case .requiresApproval:
                "Approve NotchGram in System Settings › General › Login Items."
            case .failed(let message): message
            default: nil
            }
        }
    }

    public private(set) var state: State = .unknown

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "LoginItem")
    private var poll: Task<Void, Never>?

    public init() {
        refresh()
    }

    public func refresh() {
        state = Self.map(SMAppService.mainApp.status)
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            // Approval flips asynchronously once the user acts in System
            // Settings, and nothing notifies us — so poll briefly rather than
            // leaving a stale toggle on screen.
            if state == .requiresApproval { startPolling() }
        } catch {
            log.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.state != .requiresApproval { return }
            }
        }
    }

    private static func map(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        // `.notFound` before the first registration simply means "off" — macOS
        // has no record yet. Reporting it as a failure made a fresh install look
        // broken. It only means something is wrong if the bundle is not where a
        // login item can point at it.
        case .notFound:
            Bundle.main.bundlePath.hasPrefix("/Applications")
                ? .disabled
                : .failed("Launch at login needs NotchGram in /Applications (make install).")
        @unknown default: .unknown
        }
    }
}
