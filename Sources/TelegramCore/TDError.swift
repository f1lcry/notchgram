import Foundation
@preconcurrency import TDLibKit

/// NotchGram's error type for everything that comes back from TDLib.
///
/// It exists because `TDLibKit.Error` **shadows `Swift.Error`** inside any file
/// that imports the module: unqualified `Error` there means TDLibKit's struct,
/// which silently constrains generics and `catch` clauses. TDLibKit's own
/// generated code writes `Swift.Error` everywhere for that reason. Mapping at
/// the boundary means nothing above `TelegramCore` has to know.
public struct TDError: LocalizedError, Equatable, Hashable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public init(_ error: TDLibKit.Error) {
        self.init(code: error.code, message: error.message)
    }

    /// Every `try await` on a TDLibKit request throws `TDLibKit.Error` —
    /// `run(query:)` decodes the reply as `DTO<Error>` first and wraps anything
    /// else as `Error(code: 500, …)`. Non-TDLib failures (cancellation) keep
    /// their own shape under code 0.
    public static func wrap(_ error: any Swift.Error) -> TDError {
        if let tdError = error as? TDLibKit.Error { return TDError(tdError) }
        if let already = error as? TDError { return already }
        return TDError(code: 0, message: String(describing: error))
    }

    // MARK: - Classification

    /// TDLib answers `FLOOD_WAIT_<seconds>` when a request is rate-limited.
    /// The test-DC harness regenerates its phone number rather than sleeping
    /// when this is long.
    public var floodWaitSeconds: Int? {
        guard message.hasPrefix("FLOOD_WAIT_") else { return nil }
        return Int(message.dropFirst("FLOOD_WAIT_".count))
    }

    public var isFloodWait: Bool { floodWaitSeconds != nil }

    /// 401 — the session is gone; the UI must fall back to the auth flow.
    public var isUnauthorized: Bool { code == 401 }

    public var isNotFound: Bool { code == 404 }

    /// TDLib's doc comment on `Error`: "If the error code is 406, the error
    /// message must not be processed in any way and must not be displayed to the
    /// user." Honour that rather than leaking an internal string into the panel.
    public var isSilent: Bool { code == 406 }

    /// What a human may see. `nil` means "show nothing" (code 406).
    public var userFacingMessage: String? {
        if isSilent { return nil }
        if let seconds = floodWaitSeconds {
            return "Too many attempts. Try again in \(seconds) s."
        }
        switch message {
        case "PHONE_NUMBER_INVALID": return "That phone number is not valid."
        case "PHONE_NUMBER_BANNED": return "That phone number is banned."
        case "PHONE_CODE_INVALID": return "That code is not correct."
        case "PHONE_CODE_EXPIRED": return "That code has expired. Request a new one."
        case "PASSWORD_HASH_INVALID": return "That password is not correct."
        case "FIRSTNAME_INVALID": return "That first name is not valid."
        default: return message
        }
    }

    public var errorDescription: String? { "TDLib \(code): \(message)" }
}

/// Runs a TDLibKit request and rethrows as `TDError`. Every call site in
/// `TelegramCore` goes through this so no `TDLibKit.Error` escapes the module.
///
/// The `isolated (any Actor)? = #isolation` parameter is load-bearing, not
/// decoration: without it this is a `nonisolated` async function, so the closure
/// — which captures `TDClient`'s non-Sendable `TDLibClient` — would have to
/// *cross* an isolation boundary and Swift 6 rejects it as
/// "sending value of non-Sendable type". Inheriting the caller's isolation means
/// nothing crosses anything.
@inlinable
public func td<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch {
        throw TDError.wrap(error)
    }
}
