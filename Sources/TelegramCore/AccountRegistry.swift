import Foundation

/// One configured Telegram account.
///
/// The MVP shows exactly one in the UI, but the indirection exists from day one
/// (D9): it is what makes Session 2's multi-account work additive rather than a
/// refactor, and it is also where test-DC accounts live — as ordinary accounts
/// with `useTestDc = true`, which is what lets automated testing and the real
/// account coexist without special cases.
public struct TDAccount: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable for the life of the account; names the database directory and the
    /// Keychain item, so it must never be derived from the phone number.
    public let id: String
    public var label: String
    /// The only switch needed to talk to the test DC — TDLib compiles in the
    /// test DC addresses. The production api_id works against it (verified).
    public var useTestDc: Bool
    /// For the account picker only. Never used as an identifier.
    public var phoneNumberHint: String?
    public var userId: Int64?

    public init(
        id: String = UUID().uuidString,
        label: String,
        useTestDc: Bool = false,
        phoneNumberHint: String? = nil,
        userId: Int64? = nil
    ) {
        self.id = id
        self.label = label
        self.useTestDc = useTestDc
        self.phoneNumberHint = phoneNumberHint
        self.userId = userId
    }
}

/// Where one account's TDLib state lives on disk.
public struct AccountDirectories: Equatable, Sendable {
    public let database: URL
    public let files: URL

    public func createIfNeeded() throws {
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }
}

/// Accounts, their database directories and their Keychain keys.
///
/// `UserDefaults` and `FileManager` are injected so the whole thing is testable
/// against an ephemeral suite and a temp directory — there is no singleton.
@MainActor
public final class AccountRegistry {
    public static let defaultsKey = "Accounts"
    public static let activeAccountKey = "ActiveAccountID"

    private let defaults: UserDefaults
    private let root: URL

    public init(defaults: UserDefaults = .standard, root: URL? = nil) {
        self.defaults = defaults
        self.root = root ?? Self.defaultRoot
    }

    public static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchGram/accounts")
    }

    // MARK: - Accounts

    public private(set) lazy var accounts: [TDAccount] = loadAccounts()

    public var activeAccount: TDAccount? {
        guard let id = defaults.string(forKey: Self.activeAccountKey) else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    public func setActiveAccount(_ id: String?) {
        defaults.set(id, forKey: Self.activeAccountKey)
    }

    @discardableResult
    public func upsert(_ account: TDAccount) -> TDAccount {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persist()
        return account
    }

    public func remove(id: String) {
        accounts.removeAll { $0.id == id }
        persist()
        if defaults.string(forKey: Self.activeAccountKey) == id {
            defaults.removeObject(forKey: Self.activeAccountKey)
        }
        Task { try? await KeychainStore.removeDatabaseKey(for: id) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }

    /// The account the app opens with, creating one on first launch. The MVP's
    /// single account is just this.
    public func ensureDefaultAccount() -> TDAccount {
        if let existing = activeAccount { return existing }
        let account = TDAccount(label: "Telegram")
        upsert(account)
        setActiveAccount(account.id)
        return account
    }

    // MARK: - Storage

    public func directories(for accountID: String) -> AccountDirectories {
        let base = root.appendingPathComponent(accountID)
        return AccountDirectories(
            database: base.appendingPathComponent("db"),
            files: base.appendingPathComponent("files"))
    }

    /// `async` because the Keychain blocks: `SecItemCopyMatching` is a
    /// synchronous IPC to `securityd` that does not return while a confirmation
    /// dialog is up. Doing it on the main actor froze the whole app, panel
    /// included, with no error to explain it.
    public func databaseKey(for accountID: String) async throws -> Data {
        try await KeychainStore.databaseKey(for: accountID)
    }

    private func loadAccounts() -> [TDAccount] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([TDAccount].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
