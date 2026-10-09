import Foundation
@preconcurrency import TDLibKit

/// One TDLib client, bound to one account.
///
/// Two responsibilities, both load-bearing:
///
/// 1. **It owns the `TDLibClient`.** That is a plain class with no `Sendable`
///    anywhere in TDLibKit, and it never crosses an actor boundary — only
///    Sendable results do.
///
/// 2. **It publishes exactly one ordered update stream.** TDLib's contract is
///    "all updates and responses must be handled in the order received". The
///    manager already delivers per-client updates on a serial queue; we decode
///    there and yield into an unbounded `AsyncStream`, which preserves order.
///    The stream has exactly **one** consumer, draining it in a single
///    sequential loop. Spawning a `Task` per update would destroy the ordering
///    and corrupt chat order and unread counters in ways that look random.
public actor TDClient {
    public let accountID: String

    /// `nonisolated(unsafe)` invariant: `TDLibClient` is internally thread-safe
    /// — requests go through its own concurrent query queue, completions live in
    /// a `ConcurrentDictionary` behind an `RWLock`, and updates are delivered on
    /// a per-client serial queue. Nothing here mutates it. It is never handed
    /// out; only Sendable results leave this actor.
    /// Module-internal, not private, so `TDClient+Messaging.swift` can reach it.
    /// Nothing outside `Sources/TelegramCore` may touch it — `scripts/preflight.sh`
    /// enforces that this directory stays UI-free, and the type is never handed
    /// out of the actor.
    nonisolated(unsafe) let client: TDLibClient

    /// The single ordered update stream. Drain it with one `for await` loop.
    public nonisolated let updates: AsyncStream<Update>
    private nonisolated let updateContinuation: AsyncStream<Update>.Continuation

    /// Separate from `updates` so `shutdown()` can wait for
    /// `authorizationStateClosed` without competing with the app's consumer for
    /// elements of the main stream.
    private nonisolated let closedSignal: AsyncStream<Void>
    private nonisolated let closedContinuation: AsyncStream<Void>.Continuation

    public init(accountID: String) {
        self.accountID = accountID

        let (updates, updateContinuation) = AsyncStream<Update>.makeStream(
            bufferingPolicy: .unbounded)
        let (closedSignal, closedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.updates = updates
        self.updateContinuation = updateContinuation
        self.closedSignal = closedSignal
        self.closedContinuation = closedContinuation

        // Order matters: the continuation must exist before `createClient`,
        // because `createClient` immediately sends `getOption("version")` and
        // TDLib answers by pushing `updateAuthorizationState(waitTdlibParameters)`
        // straight away. Wiring the stream up afterwards drops that first state
        // and the auth flow then waits forever for something already gone past.
        self.client = TDLibRuntime.manager.createClient { data, client in
            // `client.decoder` carries `keyDecodingStrategy = .convertFromSnakeCase`.
            // A fresh `JSONDecoder()` would fail to decode every snake_case field.
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            if case .updateAuthorizationState(let payload) = update,
               case .authorizationStateClosed = payload.authorizationState {
                closedContinuation.yield(())
            }
            updateContinuation.yield(update)
        }
    }

    // MARK: - Lifecycle

    /// Applies the 14 `setTdlibParameters` fields for this account.
    ///
    /// All 14 are non-defaulted Optionals in TDLibKit, so every call site passes
    /// all of them; `Optional` there means "encodable as null", not "omittable".
    /// The database encryption key goes in **here** — `setDatabaseEncryptionKey`
    /// only *changes* an existing key and fails as a way to set the first one.
    public func applyParameters(
        account: TDAccount,
        directories: AccountDirectories,
        databaseKey: Data,
        applicationVersion: String
    ) async throws {
        try directories.createIfNeeded()
        _ = try await td {
            try await client.setTdlibParameters(
                apiHash: Secrets.telegramApiHash,
                apiId: Secrets.telegramApiID,
                applicationVersion: applicationVersion,
                databaseDirectory: directories.database.path,
                databaseEncryptionKey: databaseKey,
                deviceModel: "Mac",
                filesDirectory: directories.files.path,
                systemLanguageCode: Self.systemLanguageCode,
                // Empty means "detect it" — TDLib reports the real OS version.
                systemVersion: "",
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: account.useTestDc)
        }
    }

    static var systemLanguageCode: String {
        Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    }

    /// Graceful close, bounded.
    ///
    /// Two traps, both hit in practice:
    ///
    /// - Never `TDLibClientManager.closeClients()`. It busy-waits
    ///   (`while (!clients.isEmpty) {}`) and runs from a `deinit`; a client that
    ///   never reports closed pegs a core forever.
    ///
    /// - Never `try await client.close()` — the **async** form. It bridges
    ///   through `withCheckedThrowingContinuation`, and the manager routes a
    ///   response by looking the client up in `clients`… *after* having removed
    ///   it on seeing `authorizationStateClosed`. When TDLib emits the closed
    ///   state before the `Ok` for `close`, that lookup returns nil, the
    ///   completion is dropped, and the continuation is **never resumed**. The
    ///   await then hangs forever — which on the quit path means the app never
    ///   exits and the operator reaches for `kill -9`, corrupting the database
    ///   D20 exists to protect. The completion form allocates no continuation,
    ///   so a dropped response costs nothing; the closed state itself is what we
    ///   actually wait on, with a deadline.
    public func shutdown(timeout: Duration = .seconds(5)) async {
        try? client.close(completion: { _ in })
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [closedSignal] in
                for await _ in closedSignal { return }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        updateContinuation.finish()
        closedContinuation.finish()
    }

    // MARK: - Authorization

    public func setPhoneNumber(_ phoneNumber: String) async throws {
        _ = try await td { try await client.setAuthenticationPhoneNumber(
            phoneNumber: phoneNumber, settings: nil) }
    }

    public func checkCode(_ code: String) async throws {
        _ = try await td { try await client.checkAuthenticationCode(code: code) }
    }

    public func checkPassword(_ password: String) async throws {
        _ = try await td { try await client.checkAuthenticationPassword(password: password) }
    }

    public func register(firstName: String, lastName: String) async throws {
        _ = try await td { try await client.registerUser(
            disableNotification: false, firstName: firstName, lastName: lastName) }
    }

    /// Not no-arg: TDLib 1.8.66 takes a `ResendCodeReason`.
    public func resendCode() async throws {
        _ = try await td { try await client.resendAuthenticationCode(
            reason: .resendCodeReasonUserRequest) }
    }

    public func setEmailAddress(_ email: String) async throws {
        _ = try await td { try await client.setAuthenticationEmailAddress(emailAddress: email) }
    }

    /// Takes an `EmailAddressAuthentication` enum, not a bare `String`.
    public func checkEmailCode(_ code: String) async throws {
        _ = try await td { try await client.checkAuthenticationEmailCode(
            code: .emailAddressAuthenticationCode(EmailAddressAuthenticationCode(code: code))) }
    }

    /// Requires a network connection and destroys all local data — that is the
    /// documented behaviour, and it is what the Settings "Log out" does.
    public func logOut() async throws {
        _ = try await td { try await client.logOut() }
    }

    // MARK: - Identity

    public func getMe() async throws -> User {
        try await td { try await client.getMe() }
    }

    public func createPrivateChat(userId: Int64, force: Bool = false) async throws -> Chat {
        try await td { try await client.createPrivateChat(force: force, userId: userId) }
    }
}
