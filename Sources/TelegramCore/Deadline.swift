import Foundation

/// A TDLib request that never answered.
///
/// This is not hypothetical. Measured on this machine: with the phone number
/// routed to test DC 3, `setAuthenticationPhoneNumber` produced
/// `PHONE_MIGRATE_3` and then TDLib sat in a connect/retry loop
/// (`Timeout expired … to DcId{3}`, `No route to host`) **without ever
/// answering the request**. TDLibKit bridges every request through
/// `withCheckedThrowingContinuation`, and task cancellation cannot resume a
/// continuation — so `await client.setPhoneNumber(…)` hangs forever, and with it
/// any UI waiting on it. A user would see a spinner that never stops and no
/// error at all.
public struct TDTimeout: LocalizedError, Equatable, Sendable {
    public let operation: String
    public let seconds: Double

    public init(operation: String, seconds: Double) {
        self.operation = operation
        self.seconds = seconds
    }

    public var errorDescription: String? {
        "\(operation) did not answer within \(Int(seconds)) s"
    }
}

/// Races `body` against a deadline.
///
/// The losing child task is cancelled, but a TDLib request that is wedged does
/// not observe cancellation — it simply stays suspended until the client is
/// closed. That is acceptable and bounded: the leak is one suspended task per
/// wedged request, and the client is torn down on shutdown. The alternative —
/// waiting forever — is not.
public func withDeadline<T: Sendable>(
    _ duration: Duration,
    operation name: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TDTimeout(
                operation: name,
                seconds: Double(duration.components.seconds))
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TDTimeout(operation: name, seconds: Double(duration.components.seconds))
        }
        return result
    }
}
