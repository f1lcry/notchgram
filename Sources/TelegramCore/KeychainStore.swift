import Foundation
import Security

/// Per-account TDLib database encryption keys (D6).
///
/// The key is passed **in** `setTdlibParameters(databaseEncryptionKey:)` —
/// `setDatabaseEncryptionKey` only *changes* an already-established key, so
/// using it to set the first one fails.
///
/// Two hazards here, both measured rather than anticipated:
///
/// **1. Keychain calls block, sometimes forever.** `SecItemCopyMatching` is a
/// synchronous IPC to `securityd`, and when `securityd` decides a confirmation
/// dialog is needed it does not return until somebody answers it. Called on the
/// main actor that froze the entire app — panel included — with the only symptom
/// being that nothing responded. Everything here is therefore reached through
/// the `async` wrappers, which run it off the main actor.
///
/// **2. The default ACL is bound to one code signature.** An item added without
/// an explicit `kSecAttrAccess` is scoped to the app that created it, so the
/// Apple Development (Debug) build and the Developer ID (Release) build are two
/// different applications as far as the keychain is concerned — and the second
/// one to run gets the confirmation dialog. That is not a corner case for this
/// project: D11 requires exactly those two signatures, and D20 puts the Release
/// build in `/Applications` where nobody is watching it. The item is created
/// with an ACL that trusts any application instead.
///
/// The trade is deliberate and small: the secret is a local database key, and
/// the encrypted database sits next to it in `~/Library/Application Support`
/// under the same user's permissions. Anything that could read the key with a
/// permissive ACL could already read the database file itself.
///
/// Deliberately the classic (file) keychain: the data-protection keychain needs
/// a `keychain-access-groups` entitlement, and adding any App-ID-scoped
/// entitlement is what would force a registered App ID and provisioning profiles
/// on a project that is otherwise profile-free.
///
/// The headless test-DC harness never calls this — it generates a throwaway key
/// per run — because a keychain prompt would break an unattended run.
public enum KeychainStore {
    public static let service = "com.f1lcry.notchgram.tdlib-db-key"

    public enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case randomFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            case .randomFailed(let status):
                return "SecRandomCopyBytes failed: \(status)"
            }
        }
    }

    // MARK: - Async surface (the one callers should use)

    /// Returns the account's key, creating a fresh 256-bit one on first use.
    /// Runs off the caller's actor: see hazard 1 above.
    public static func databaseKey(for accountID: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try databaseKeySynchronously(for: accountID)
        }.value
    }

    public static func removeDatabaseKey(for accountID: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }.value
    }

    // MARK: - Synchronous internals

    /// **Blocking.** Only call this off the main actor.
    static func databaseKeySynchronously(for accountID: String) throws -> Data {
        if let existing = try read(accountID) { return existing }
        let key = try randomKey()
        try write(key, for: accountID)
        return key
    }

    static func randomKey(byteCount: Int = 32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else { throw KeychainError.randomFailed(status) }
        return Data(bytes)
    }

    private static func baseQuery(_ accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    private static func read(_ accountID: String) throws -> Data? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func write(_ key: Data, for accountID: String) throws {
        var attributes = baseQuery(accountID)
        attributes[kSecValueData as String] = key
        // The app is a background agent that must reach TDLib after a reboot
        // without the user unlocking anything beyond login.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let access = permissiveAccess() {
            attributes[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: key]
            let updateStatus = SecItemUpdate(
                baseQuery(accountID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// An ACL whose application list is `nil`, which the Keychain reads as "any
    /// application" — see hazard 2 above. Returns nil if the (deprecated but
    /// still functional) API is unavailable, in which case the item is created
    /// with the default single-signature ACL and the caller may see a
    /// confirmation dialog after a signing-identity change.
    private static func permissiveAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("NotchGram TDLib database key" as CFString, nil, &access)
                == errSecSuccess,
              let access
        else { return nil }

        guard let acls = SecAccessCopyMatchingACLList(
            access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return access }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt)
                    == errSecSuccess
            else { continue }
            // nil application list == every application is trusted, and an empty
            // prompt selector == do not ask.
            _ = SecACLSetContents(acl, nil, (description ?? "" as CFString), [])
        }
        return access
    }
}
