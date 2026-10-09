import Foundation
import TDLibFramework
@preconcurrency import TDLibKit

/// Process-wide TDLib runtime: logging configuration and the single client
/// manager everything else hangs off.
public enum TDLibRuntime {

    // MARK: - Manager

    /// **HAZARD — this must never deallocate.** `TDLibClientManager.deinit`
    /// calls `closeClients()`, whose body ends in
    /// `while (!self.clients.isEmpty) {}` — a busy-wait. A client that never
    /// reaches `authorizationStateClosed` would spin a core forever, from a
    /// `deinit`, with no way out. A `static let` in an enum is created once and
    /// never released, which is exactly the lifetime we want. Shutdown goes
    /// through `TDClient.shutdown()` (per-client `close` with a timeout), never
    /// through `closeClients()`.
    ///
    /// `nonisolated(unsafe)` invariant: `TDLibClientManager` is internally
    /// thread-safe — `clients` is a `ConcurrentDictionary` behind an `RWLock`,
    /// each client owns a serial update queue, and requests go through the
    /// client's own concurrent query queue. We only ever call `createClient`.
    ///
    /// TDLib's `td_receive` may be called from exactly one thread; this manager
    /// owns that thread. One manager per process, one client id per account —
    /// which is also what makes Session 2's multi-account work additive.
    nonisolated(unsafe) public static let manager: TDLibClientManager = {
        configureLogging()
        return TDLibClientManager()
    }()

    // MARK: - Logging

    /// Where TDLib's own log goes. Deliberately *not* stderr: at any verbosity
    /// above 1 TDLib logs request and update payloads, which after CP1 means the
    /// founder's real chat content. Keeping it in one capped file under
    /// Application Support (rather than in `.artifacts/` or the run logs) keeps
    /// it out of anything an agent reads or a report quotes.
    public static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchGram/logs/tdlib.log")
    }

    /// Verbosity: 0 fatal, 1 errors, 2 warnings, 3 info, 4 debug, 5 verbose.
    /// Default 1. Override with `NOTCHGRAM_TDLIB_VERBOSITY` when debugging.
    public static var verbosity: Int {
        ProcessInfo.processInfo.environment["NOTCHGRAM_TDLIB_VERBOSITY"].flatMap(Int.init) ?? 1
    }

    /// Runs *before* the manager exists, which is the only way to avoid the
    /// burst TDLib emits from `td_create_client_id` onwards. `td_execute` is
    /// synchronous, process-global and documented as valid before initialization
    /// for exactly these two requests.
    private static func configureLogging() {
        execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": verbosity])

        let url = logFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        execute([
            "@type": "setLogStream",
            "log_stream": [
                "@type": "logStreamFile",
                "path": url.path,
                "max_file_size": 8 * 1024 * 1024,
                // false on purpose: `true` swallows OUR stderr into TDLib's log,
                // which would silently empty .artifacts/run.err.log.
                "redirect_stderr": false,
            ],
        ])
    }

    @discardableResult
    private static func execute(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let result = td_execute(json)
        else { return nil }
        return String(cString: result)
    }

    // MARK: - Synchronous probes

    /// `version` and `commit_hash` are the only two options TDLib answers
    /// synchronously, before any client exists — which is what lets M0's gate G2
    /// prove the static framework links and runs without creating (and then
    /// having to dispose of) a client.
    public static func option(_ name: String) -> String? {
        guard let response = execute(["@type": "getOption", "name": name]),
              let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["@type"] as? String == "optionValueString"
        else { return nil }
        return object["value"] as? String
    }
}

/// M0 gate G2 in one call: proves the *static* TDLibFramework xcframework links,
/// signs and executes inside the real signed bundle under Xcode 26.6 — the one
/// thing TDLibKit's own CI (Xcode 16.4 / macOS 15) does not cover.
public enum TDLibProbe {
    public static func version() -> String? { TDLibRuntime.option("version") }
    public static func commitHash() -> String? { TDLibRuntime.option("commit_hash") }
}
