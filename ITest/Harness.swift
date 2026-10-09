import Foundation
@preconcurrency import TDLibKit

/// One disposable test-DC session, driven through the app's own `TDClient` and
/// `AuthFlow`. A harness with its own parallel copy of the auth logic proves
/// only that the copy works.
///
/// An `actor` because a background consumer task and the step script both touch
/// its state; that is also what makes the "wait until X" helpers safe.
actor Harness {
    nonisolated let account: TestAccount
    nonisolated let client: TDClient
    nonisolated let directories: AccountDirectories
    nonisolated let root: URL

    private(set) var authState: AuthState = .initializing
    private var trailStates: [String] = []
    private var answerFailure: String?

    /// Keyed by the **temporary** message id the send returned.
    /// `updateMessageSendSucceeded` replaces the whole object — "almost any
    /// field can be different" — so nothing may be patched in place.
    private var sendSucceeded: [Int64: Message] = [:]
    private var sendFailed: [Int64: String] = [:]
    private var files: [Int: File] = [:]

    private var consumer: Task<Void, Never>?

    init(account: TestAccount) throws {
        self.account = account
        self.root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".artifacts/itest/run-\(UUID().uuidString.prefix(8))")
        self.directories = AccountDirectories(
            database: root.appendingPathComponent("db"),
            files: root.appendingPathComponent("files"))
        try directories.createIfNeeded()
        self.client = TDClient(accountID: "itest-\(account.phoneNumber)")
    }

    var trail: String { trailStates.joined(separator: " → ") }
    var failure: String? { answerFailure }

    nonisolated func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Update consumption

    /// One loop, one update at a time — the same ordering discipline the app
    /// uses. Auth states are answered inline; everything else is recorded for
    /// the step script to wait on.
    func start() {
        guard consumer == nil else { return }
        consumer = Task { [weak self] in
            guard let self else { return }
            for await update in await self.client.updates {
                await self.handle(update)
            }
        }
    }

    func stop() async {
        consumer?.cancel()
        consumer = nil
        await client.shutdown()
    }

    private func handle(_ update: Update) async {
        switch update {
        case .updateAuthorizationState(let payload):
            let state = AuthFlow.state(from: payload.authorizationState)
            authState = state
            trailStates.append(state.name)
            note("state → \(state.name)")
            await answer(state)

        case .updateMessageSendSucceeded(let payload):
            sendSucceeded[payload.oldMessageId] = payload.message

        case .updateMessageSendFailed(let payload):
            sendFailed[payload.oldMessageId] = payload.error.message

        case .updateFile(let payload):
            files[payload.file.id] = payload.file

        default:
            break
        }
    }

    /// Every request is bounded. A TDLib request to an unreachable data centre
    /// never answers *and never errors*, and TDLibKit's continuation cannot be
    /// cancelled — without a deadline the harness hangs instead of failing over.
    private func answer(_ state: AuthState) async {
        let client = self.client
        let directories = self.directories
        do {
            switch state {
            case .initializing:
                let account = TDAccount(id: client.accountID, label: "itest", useTestDc: true)
                // Never a Keychain lookup: a prompt would break an unattended
                // run, and test-DC state is disposable by design.
                let key = try KeychainStore.randomKey()
                try await withDeadline(.seconds(20), operation: "setTdlibParameters") {
                    try await client.applyParameters(
                        account: account,
                        directories: directories,
                        databaseKey: key,
                        applicationVersion: "NotchGram ITest")
                }

            case .waitPhoneNumber:
                let phoneNumber = account.phoneNumber
                try await withDeadline(.seconds(25), operation: "setAuthenticationPhoneNumber") {
                    try await client.setPhoneNumber(phoneNumber)
                }

            case .waitCode(let challenge):
                try await submitCode(challenge)

            // A fresh test-DC number is unregistered, so this is the NORMAL
            // path here — a harness that handles only waitCode → ready hangs
            // forever on its very first run.
            case .waitRegistration:
                try await withDeadline(.seconds(25), operation: "registerUser") {
                    try await client.register(firstName: "NotchGram", lastName: "ITest")
                }

            case .waitPassword:
                throw TDError(code: 0, message: "test-DC account unexpectedly has 2FA")

            default:
                break
            }
        } catch let error as TDError {
            answerFailure = error.floodWaitSeconds.map { "FLOOD_WAIT_\($0)" } ?? error.message
            note("error answering \(state.name): \(answerFailure ?? "?")")
        } catch let timeout as TDTimeout {
            answerFailure = timeout.errorDescription
            note("timeout: \(answerFailure ?? "?") — data centre unreachable?")
        } catch {
            answerFailure = String(describing: error)
            note("error answering \(state.name): \(answerFailure ?? "?")")
        }
    }

    /// The documented test-DC rule is "the DC number repeated five times", and
    /// `codeInfo.type` agrees (`authenticationCodeTypeSms { length = 5 }`) — but
    /// the server rejected exactly that with `PHONE_CODE_INVALID` for
    /// `99966**1**8856` / `11111`, verified in TDLib's own request log. Rather
    /// than encode a guess, try the documented form first and then a couple of
    /// near variants, remembering whichever the server actually accepts.
    ///
    /// TDLib stays in `waitCode` after a rejected code, so retrying in place is
    /// legal; the attempt count is kept small because wrong codes count toward
    /// the flood limit.
    private func submitCode(_ challenge: CodeChallenge) async throws {
        guard let reported = challenge.kind.expectedLength else {
            throw TDError(code: 0, message: "non-numeric code type on the test DC")
        }

        var candidates = [reported]
        if let remembered = CodeLengthPreference.load(), !candidates.contains(remembered) {
            candidates.insert(remembered, at: 0)
        }
        for extra in [6, 5, 4] where !candidates.contains(extra) { candidates.append(extra) }

        let client = self.client
        var lastError: TDError?
        for length in candidates {
            let code = account.code(length: length)
            do {
                try await withDeadline(.seconds(25), operation: "checkAuthenticationCode") {
                    try await client.checkCode(code)
                }
                if length != reported {
                    note("code length \(length) accepted (codeInfo reported \(reported))")
                }
                CodeLengthPreference.remember(length)
                return
            } catch let error as TDError where error.message == "PHONE_CODE_INVALID" {
                note("code \(code) rejected; trying another length")
                lastError = error
            }
        }
        throw lastError ?? TDError(code: 0, message: "no candidate code accepted")
    }

    // MARK: - Waiting

    /// Polls rather than parking on a continuation: the actor yields at every
    /// sleep, so the consumer loop keeps draining, and there is no continuation
    /// that a never-arriving update could strand.
    private func waitUntil<T: Sendable>(
        _ what: String,
        deadline: Duration,
        _ probe: (isolated Harness) -> T?
    ) async throws -> T {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if let failure = answerFailure {
                throw TDError(code: 0, message: failure)
            }
            if let value = probe(self) { return value }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw TDTimeout(operation: what, seconds: Double(deadline.components.seconds))
    }

    func waitForCode(deadline: Duration = .seconds(40)) async throws -> CodeChallenge {
        try await waitUntil("authorizationStateWaitCode", deadline: deadline) {
            if case .waitCode(let challenge) = $0.authState { return challenge }
            return nil
        }
    }

    func waitForReady(deadline: Duration = .seconds(60)) async throws {
        _ = try await waitUntil("authorizationStateReady", deadline: deadline) {
            $0.authState == .ready ? true : nil
        }
    }

    func waitForSendSucceeded(
        temporaryId: Int64,
        deadline: Duration = .seconds(45)
    ) async throws -> Message {
        try await waitUntil("updateMessageSendSucceeded", deadline: deadline) {
            if let error = $0.sendFailed[temporaryId] {
                // Surfaced through the normal failure channel on the next poll.
                $0.answerFailure = "send failed: \(error)"
            }
            return $0.sendSucceeded[temporaryId]
        }
    }

    /// Render only when `isDownloadingCompleted` is true **and** the path is
    /// non-empty: `local.path` may point at a partial file, and TDLib's own
    /// docs warn that bytes on disk are garbage until completion.
    func waitForDownload(fileId: Int, deadline: Duration = .seconds(45)) async throws -> File {
        try await waitUntil("file download", deadline: deadline) {
            guard let file = $0.files[fileId],
                  file.local.isDownloadingCompleted,
                  !file.local.path.isEmpty
            else { return nil }
            return file
        }
    }

    func waitForUpload(fileId: Int, deadline: Duration = .seconds(45)) async throws -> File {
        try await waitUntil("file upload", deadline: deadline) {
            guard let file = $0.files[fileId], file.remote.isUploadingCompleted else { return nil }
            return file
        }
    }
}
