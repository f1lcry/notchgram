import Foundation
import Observation
import os
@preconcurrency import TDLibKit

/// One row of the "Messages" section: a found message, presented the way
/// Telegram presents it — the chat's row chrome with the message as preview.
public struct MessageSearchHit: Identifiable, Equatable, Hashable, Sendable {
    public let chatId: Int64
    public let messageId: Int64
    /// The chat's row (title, avatar), with `preview`/`date` swapped for the
    /// found message's.
    public let chat: ChatSummary

    public var id: String { "\(chatId):\(messageId)" }
}

/// Chat and message search, as Telegram structures it.
///
/// Four sources, two sections:
///
/// - **Chats**: `searchChats` is local and instant, so it answers on every
///   keystroke; `searchChatsOnServer` and `searchPublicChats` are network
///   round trips and are debounced. Ids from all three resolve through the
///   repo's summary cache — TDLib guarantees `updateNewChat` precedes any id
///   it returns, so resolution is a dictionary hit, not a round trip.
/// - **Messages**: `searchMessages` — global full-text search over every
///   non-secret chat, reverse-chronological.
@MainActor
@Observable
public final class ChatSearch {
    public private(set) var results: [ChatSummary] = []
    public private(set) var messageResults: [MessageSearchHit] = []
    public private(set) var isSearching = false

    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            schedule()
        }
    }

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "ChatSearch")
    private weak var client: TDClient?
    private weak var repo: ChatRepo?
    private var debounce: Task<Void, Never>?
    /// Generation token: a stale remote pass must not overwrite a newer one.
    private var generation = 0

    public init() {}

    public func attach(client: TDClient, repo: ChatRepo) {
        self.client = client
        self.repo = repo
    }

    public var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public func clear() {
        query = ""
        results = []
        messageResults = []
        debounce?.cancel()
        debounce = nil
        generation += 1
    }

    private func schedule() {
        debounce?.cancel()
        generation += 1
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            messageResults = []
            return
        }

        // The local pass runs immediately so the list never feels laggy; only
        // the network passes wait.
        applyLocal(text)

        let expected = generation
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.runRemote(text, generation: expected)
        }
    }

    /// Substring match over what is already loaded. Instant, and correct for the
    /// overwhelmingly common case of finding a chat you already have.
    private func applyLocal(_ text: String) {
        guard let repo else { return }
        let lowered = text.lowercased()
        results = repo.chats.filter { $0.title.lowercased().contains(lowered) }
    }

    private func runRemote(_ text: String, generation expected: Int) async {
        guard let client, let repo else { return }
        isSearching = true
        defer { isSearching = false }

        // The four requests are independent; fire them together.
        async let localTask = client.searchChats(query: text)
        async let serverTask = client.searchChatsOnServer(query: text)
        async let publicTask = client.searchPublicChats(query: text)
        async let messagesTask = client.searchMessages(query: text, limit: 20)

        do {
            let ids = try await localTask
            // The server passes are best-effort extensions: offline, the local
            // section still answers.
            let serverIds = (try? await serverTask) ?? []
            let publicIds = (try? await publicTask) ?? []
            let messages = (try? await messagesTask) ?? []
            guard expected == generation else { return }

            // Preserve TDLib's ranking: known chats first, then public finds,
            // then anything the substring filter caught that no request
            // mentioned (e.g. a folder-only chat matched by title).
            var ordered: [Int64] = []
            for id in ids + serverIds + publicIds where !ordered.contains(id) {
                ordered.append(id)
            }
            var merged = ordered.compactMap { repo.cachedSummary(id: $0) }
            for local in results where !merged.contains(where: { $0.id == local.id }) {
                merged.append(local)
            }
            results = merged

            messageResults = messages.compactMap { message in
                guard var chat = repo.cachedSummary(id: message.chatId) else { return nil }
                chat.preview = MessagePreview.text(for: message.content, language: .system)
                chat.date = message.date
                // Row chrome that belongs to the chat, not the hit.
                chat.unreadCount = 0
                chat.unreadMentionCount = 0
                chat.isPinned = false
                chat.hasDraft = false
                chat.showsReadTicks = false
                chat.showsUnreadTicks = false
                return MessageSearchHit(
                    chatId: message.chatId, messageId: message.id, chat: chat)
            }
        } catch {
            log.error("search failed: \(TDError.wrap(error).message, privacy: .public)")
        }
    }
}
