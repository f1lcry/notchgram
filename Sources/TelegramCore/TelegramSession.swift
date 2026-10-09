import Foundation
import Observation
import os
@preconcurrency import TDLibKit

/// Anything that wants to see the update stream registers here. Sinks are
/// invoked **in order, synchronously, on the main actor** from the single drain
/// loop — that is the whole ordering guarantee, and it is why no sink may spawn
/// a `Task` to do its work.
@MainActor
public protocol TelegramUpdateSink: AnyObject {
    func apply(_ update: Update)
}

/// The account-level object the UI talks to: owns the client, drives the
/// authorization state machine, and drains the update stream.
@MainActor
@Observable
public final class TelegramSession {

    // MARK: - Published state

    /// What the UI should render. Normally the live state; when DebugBridge
    /// has forced one, that instead.
    public var authState: AuthState { debugAuthStateOverride ?? liveAuthState }
    public private(set) var liveAuthState: AuthState = .initializing

    /// DebugBridge `gotoAuthState`. Overriding the *rendered* state — rather
    /// than trying to push TDLib into it — is what makes all thirteen auth
    /// screens reachable for review without thirteen real accounts, and without
    /// any risk of driving the founder's session somewhere it should not go.
    public var debugAuthStateOverride: AuthState?
    public private(set) var connectionState: TDConnectionState = .connecting
    /// Last failure from a user-initiated action, for the auth screens. Cleared
    /// whenever a new action starts.
    public private(set) var lastError: TDError?
    public private(set) var me: User?
    public private(set) var isBusy = false

    public let account: TDAccount

    // MARK: - Internals

    private let registry: AccountRegistry
    private let applicationVersion: String
    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "TelegramSession")

    /// The account's client. Exposed so repos can issue requests; it is an
    /// actor, so handing it out crosses no isolation boundary.
    public private(set) var client: TDClient?
    private var drainTask: Task<Void, Never>?
    private var sinks: [any TelegramUpdateSink] = []
    private weak var chatRepo: ChatRepo?
    private weak var messageRepo: MessageRepo?
    /// Guards against answering `waitTdlibParameters` twice, which TDLib rejects.
    private var parametersApplied = false
    /// Disk-cache rotation runs once per launch, on reaching ready.
    private var storageOptimized = false

    public init(account: TDAccount, registry: AccountRegistry, applicationVersion: String) {
        self.account = account
        self.registry = registry
        self.applicationVersion = applicationVersion
    }

    public func addSink(_ sink: any TelegramUpdateSink) {
        sinks.append(sink)
    }

    /// Registers the stores and wires them to the client. Call after `start()`,
    /// so the client exists.
    public func attachRepos(
        chat: ChatRepo,
        messages: MessageRepo,
        files: FileStore,
        folders: ChatFolders
    ) {
        chatRepo = chat
        messageRepo = messages
        addSink(chat)
        addSink(messages)
        addSink(files)
        addSink(folders)
        if let client {
            chat.attach(client: client)
            messages.attach(client: client)
            files.attach(client: client)
            folders.attach(client: client)
        }
    }

    /// DebugBridge only: pushes a synthesized update through the **same** path a
    /// real one takes.
    ///
    /// This is what makes the chat list, the conversation and the media views
    /// buildable and screenshottable before an account exists — which stopped
    /// being a convenience the moment Telegram's test DC turned out to be
    /// unusable (D29). Deliberately does not touch the authorization state
    /// machine: `debugAuthStateOverride` is the supported way to move that, and
    /// driving the real one from a fixture could take the founder's session
    /// somewhere it should not go.
    public func injectUpdate(_ update: Update) {
        for sink in sinks { sink.apply(update) }
    }

    #if DEBUG
    /// Demo mode (`NOTCHGRAM_DEMO=1`, Debug builds only): renders the signed-in
    /// client with **no TDLib client at all** — no database, no Keychain, no
    /// network. The content then arrives through `injectUpdate`, i.e. through
    /// exactly the sink path real updates take, so what is on screen is the
    /// real UI over fictional data.
    public func enterOfflineDemo(me: User) {
        precondition(client == nil, "demo mode must never run beside a live client")
        self.me = me
        liveAuthState = .ready
        connectionState = .ready
        chatRepo?.myUserId = me.id
    }
    #endif

    // MARK: - Lifecycle

    public func start() {
        guard client == nil else { return }
        let client = TDClient(accountID: account.id)
        self.client = client

        // One loop, one update at a time, awaited inline. Do NOT turn this into
        // `Task { await apply(update) }` — TDLib requires updates to be handled
        // in the order received, and per-update tasks silently reorder them.
        chatRepo?.attach(client: client)
        messageRepo?.attach(client: client)
        drainTask = Task { [weak self] in
            for await update in client.updates {
                guard let self else { return }
                await self.apply(update)
            }
        }
    }

    /// Bounded, graceful. Called from `applicationWillTerminate`; TDLib holds an
    /// encrypted SQLite database open and a hard kill risks corrupting it.
    public func shutdown() async {
        drainTask?.cancel()
        drainTask = nil
        await client?.shutdown()
        client = nil
    }

    // MARK: - Update handling

    private func apply(_ update: Update) async {
        switch update {
        case .updateAuthorizationState(let payload):
            await handleAuthorizationState(payload.authorizationState)
        case .updateConnectionState(let payload):
            connectionState = TDConnectionState(payload.state)
        default:
            break
        }

        for sink in sinks { sink.apply(update) }
    }

    private func handleAuthorizationState(_ state: AuthorizationState) async {
        let mapped = AuthFlow.state(from: state)
        liveAuthState = mapped
        log.notice("auth → \(mapped.name, privacy: .public)")

        switch state {
        case .authorizationStateWaitTdlibParameters:
            await sendParameters()
        case .authorizationStateReady:
            parametersApplied = true
            lastError = nil
            await refreshMe()
            if !storageOptimized {
                storageOptimized = true
                await client?.optimizeStorage(sizeLimit: 8 << 30, ttlSeconds: 30 * 86_400)
            }
        case .authorizationStateClosed:
            client = nil
        default:
            break
        }
    }

    private func sendParameters() async {
        guard !parametersApplied, let client else { return }
        parametersApplied = true
        do {
            let directories = registry.directories(for: account.id)
            let key = try await registry.databaseKey(for: account.id)
            try await client.applyParameters(
                account: account,
                directories: directories,
                databaseKey: key,
                applicationVersion: applicationVersion)
        } catch {
            parametersApplied = false
            let mapped = TDError.wrap(error)
            lastError = mapped
            log.error("setTdlibParameters failed: \(mapped.errorDescription ?? "?", privacy: .public)")
        }
    }

    private func refreshMe() async {
        guard let client else { return }
        do {
            me = try await client.getMe()
            chatRepo?.myUserId = me?.id
            if let me {
                var updated = account
                updated.userId = me.id
                updated.phoneNumberHint = me.phoneNumber.isEmpty ? nil : me.phoneNumber
                registry.upsert(updated)
            }
        } catch {
            log.error("getMe failed: \(TDError.wrap(error).message, privacy: .public)")
        }
    }

    // MARK: - Auth actions

    public func submitPhoneNumber(_ phoneNumber: String) async {
        await perform("setAuthenticationPhoneNumber") { try await $0.setPhoneNumber(phoneNumber) }
    }

    public func submitCode(_ code: String) async {
        await perform("checkAuthenticationCode") { try await $0.checkCode(code) }
    }

    public func submitPassword(_ password: String) async {
        await perform("checkAuthenticationPassword") { try await $0.checkPassword(password) }
    }

    public func submitRegistration(firstName: String, lastName: String) async {
        await perform("registerUser") { try await $0.register(firstName: firstName, lastName: lastName) }
    }

    public func submitEmailAddress(_ email: String) async {
        await perform("setAuthenticationEmailAddress") { try await $0.setEmailAddress(email) }
    }

    public func submitEmailCode(_ code: String) async {
        await perform("checkAuthenticationEmailCode") { try await $0.checkEmailCode(code) }
    }

    public func resendCode() async {
        await perform("resendAuthenticationCode") { try await $0.resendCode() }
    }

    public func logOut() async {
        await perform("logOut", timeout: .seconds(20)) { try await $0.logOut() }
    }

    /// Every user-initiated action goes through here: clears the previous error,
    /// marks the UI busy, bounds the request with a deadline, and maps whatever
    /// TDLib throws into a `TDError` the auth screens can render.
    ///
    /// The deadline is not defensive padding. A TDLib request whose data centre
    /// is unreachable never answers *and never errors* — verified against test
    /// DC 3 from this network — and TDLibKit's continuation cannot be cancelled.
    /// Without this the panel would spin forever with nothing to show.
    private func perform(
        _ name: String,
        timeout: Duration = .seconds(45),
        _ body: @escaping @Sendable (TDClient) async throws -> Void
    ) async {
        guard let client else {
            lastError = TDError(code: 0, message: "Telegram client is not running")
            return
        }
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await withDeadline(timeout, operation: name) { try await body(client) }
        } catch let timeout as TDTimeout {
            let mapped = TDError(
                code: 0,
                message: timeout.errorDescription ?? "request timed out")
            lastError = mapped
            log.error("\(name, privacy: .public) timed out")
        } catch {
            let mapped = TDError.wrap(error)
            lastError = mapped
            log.error("action failed: \(mapped.errorDescription ?? "?", privacy: .public)")
        }
    }
}
