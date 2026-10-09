import Foundation
@preconcurrency import TDLibKit

/// Chat, message and file requests.
///
/// Every signature here is copied from the pinned generated sources
/// (`docs/reference/tdlibkit-api.md`) rather than from memory: TDLibKit orders
/// parameters **alphabetically**, not in TL order, so `downloadFile` is
/// `(fileId:limit:offset:priority:synchronous:)` and `getChatHistory` is
/// `(chatId:fromMessageId:limit:offset:onlyLocal:)`.
extension TDClient {

    // MARK: - Storage

    /// Rotates TDLib's on-disk file cache the way the official apps do: past
    /// `sizeLimit` or `ttlSeconds` since last access, files go LRU-first
    /// (TDLib's defaults already spare thumbnails, profile photos, stickers
    /// and wallpapers). TDLib performs **no** rotation on its own — without
    /// this the media cache grows for the install's lifetime. Completion form
    /// on purpose: fire-and-forget housekeeping must never hang a
    /// continuation (compare D28).
    public func optimizeStorage(sizeLimit: Int64, ttlSeconds: Int) {
        try? client.optimizeStorage(
            chatIds: nil,
            chatLimit: nil,
            count: 40_000,
            excludeChatIds: nil,
            fileTypes: nil,
            immunityDelay: 3600,
            returnDeletedFileStatistics: false,
            size: sizeLimit,
            ttl: ttlSeconds) { _ in }
    }

    // MARK: - Speech recognition

    /// Telegram's own transcription for a voice/video note. Fire-and-forget:
    /// the result streams back through `updateMessageContent` as the message's
    /// `speech_recognition_result` (pending → text/error), which the repo
    /// already applies. Premium-gated; free accounts get a weekly trial and
    /// the error case carries Telegram's own explanation.
    public func recognizeSpeech(chatId: Int64, messageId: Int64) {
        try? client.recognizeSpeech(chatId: chatId, messageId: messageId) { _ in }
    }

    // MARK: - Chats

    /// Asks TDLib to load more of a chat list. It answers `Ok` and delivers the
    /// chats through `updateNewChat` + position updates; when the list is
    /// exhausted it fails with 404, which is a normal end-of-list signal and not
    /// an error worth surfacing.
    public func loadChats(chatList: ChatList = .chatListMain, limit: Int = 40) async throws {
        _ = try await td { try await client.loadChats(chatList: chatList, limit: limit) }
    }

    public func getChat(chatId: Int64) async throws -> Chat {
        try await td { try await client.getChat(chatId: chatId) }
    }

    /// In supergroups and channels TDLib delivers message updates **only for
    /// opened chats**, so this bracket is what makes a conversation live.
    public func openChat(chatId: Int64) async throws {
        _ = try await td { try await client.openChat(chatId: chatId) }
    }

    public func closeChat(chatId: Int64) async throws {
        _ = try await td { try await client.closeChat(chatId: chatId) }
    }

    // MARK: - History

    /// One page of history. The caller is expected to **loop**: TDLib documents
    /// that the first call on a cold cache may return 0–1 messages regardless of
    /// `limit`, and a response of 0 is the end-of-history signal.
    public func chatHistory(
        chatId: Int64,
        fromMessageId: Int64 = 0,
        offset: Int = 0,
        limit: Int = 50,
        onlyLocal: Bool = false
    ) async throws -> [Message] {
        let messages = try await td {
            try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: offset,
                onlyLocal: onlyLocal)
        }
        return messages.messages ?? []
    }

    // MARK: - Sending

    /// TDLib's send-correlation token. It comes back in
    /// `messageSendingStatePending.sendingId` and lets the UI match its
    /// optimistic row to the real message — the temporary message id must not be
    /// used for that, because `updateMessageSendSucceeded` replaces the whole
    /// object and "almost any field can be different".
    ///
    /// Note the type is `Int`, not `Int64` and not `TdInt64`.
    public nonisolated static func newSendingId() -> Int {
        Int.random(in: 1...Int(Int32.max))
    }

    /// All 11 fields are non-Optional except two, so there is no partial init.
    public nonisolated static func sendOptions(sendingId: Int) -> MessageSendOptions {
        MessageSendOptions(
            allowPaidBroadcast: false,
            disableNotification: false,
            effectId: TdInt64(0),
            fromBackground: false,
            onlyPreview: false,
            paidMessageStarCount: 0,
            protectContent: false,
            schedulingState: nil,
            sendingId: sendingId,
            suggestedPostInfo: nil,
            updateOrderOfInstalledStickerSets: false)
    }

    @discardableResult
    public func sendText(
        chatId: Int64,
        text: String,
        replyTo: InputMessageReplyTo? = nil,
        sendingId: Int
    ) async throws -> Message {
        try await td {
            try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: .inputMessageText(InputMessageText(
                    clearDraft: true,
                    linkPreviewOptions: nil,
                    text: FormattedText(entities: [], text: text))),
                options: Self.sendOptions(sendingId: sendingId),
                replyMarkup: nil,
                replyTo: replyTo,
                // `topicId` is a `MessageTopic?`, not a thread id. A plain 1-1
                // send passes nil. Any pre-1.8.6x snippet omits this entirely
                // and will not compile.
                topicId: nil)
        }
    }

    /// `inputMessagePhoto` nests an `InputPhoto` wrapper in 1.8.66 — the photo
    /// is not a direct field of the message content.
    @discardableResult
    public func sendPhoto(
        chatId: Int64,
        path: String,
        width: Int,
        height: Int,
        caption: String? = nil,
        replyTo: InputMessageReplyTo? = nil,
        sendingId: Int
    ) async throws -> Message {
        try await td {
            try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: .inputMessagePhoto(InputMessagePhoto(
                    caption: caption.map { FormattedText(entities: [], text: $0) },
                    hasSpoiler: false,
                    photo: InputPhoto(
                        addedStickerFileIds: [],
                        height: height,
                        photo: .inputFileLocal(InputFileLocal(path: path)),
                        thumbnail: nil,
                        video: nil,
                        width: width),
                    selfDestructType: nil,
                    showCaptionAboveMedia: false)),
                options: Self.sendOptions(sendingId: sendingId),
                replyMarkup: nil,
                replyTo: replyTo,
                topicId: nil)
        }
    }

    @discardableResult
    public func sendDocument(
        chatId: Int64,
        path: String,
        caption: String? = nil,
        replyTo: InputMessageReplyTo? = nil,
        sendingId: Int
    ) async throws -> Message {
        try await td {
            try await client.sendMessage(
                chatId: chatId,
                // Like `inputMessagePhoto`, this nests a wrapper (`InputDocument`)
                // in 1.8.66 rather than taking the file directly.
                inputMessageContent: .inputMessageDocument(InputMessageDocument(
                    caption: caption.map { FormattedText(entities: [], text: $0) },
                    document: InputDocument(
                        disableContentTypeDetection: false,
                        document: .inputFileLocal(InputFileLocal(path: path)),
                        thumbnail: nil))),
                options: Self.sendOptions(sendingId: sendingId),
                replyMarkup: nil,
                replyTo: replyTo,
                topicId: nil)
        }
    }

    // MARK: - Notifications

    public func setChatNotificationSettings(
        chatId: Int64,
        settings: ChatNotificationSettings
    ) async throws {
        _ = try await td {
            try await client.setChatNotificationSettings(
                chatId: chatId, notificationSettings: settings)
        }
    }

    // MARK: - Read state

    /// Essential for a panel that is usually collapsed: without `forceRead`
    /// TDLib will not mark messages read for a client it considers inactive.
    public func viewMessages(chatId: Int64, messageIds: [Int64], forceRead: Bool = true) async throws {
        _ = try await td {
            try await client.viewMessages(
                chatId: chatId,
                forceRead: forceRead,
                messageIds: messageIds,
                source: nil)
        }
    }

    // MARK: - Search

    /// Local, instant, and limited to chats TDLib already knows about.
    public func searchChats(query: String, limit: Int = 20) async throws -> [Int64] {
        // `typeFilter: nil` means every chat type — 1.8.66 added the parameter
        // and it is not optional-with-default.
        let chats = try await td {
            try await client.searchChats(limit: limit, query: query, typeFilter: nil)
        }
        return chats.chatIds
    }

    /// Server-side, for chats not in the local list. Worth debouncing: it is a
    /// network round trip on every keystroke otherwise.
    public func searchChatsOnServer(query: String, limit: Int = 20) async throws -> [Int64] {
        let chats = try await td {
            try await client.searchChatsOnServer(limit: limit, query: query, typeFilter: nil)
        }
        return chats.chatIds
    }

    /// Public chats by username and title — Telegram's "global search" section.
    /// Deliberately excludes chats already in the chat list, so its results
    /// only ever *extend* the two searches above.
    public func searchPublicChats(query: String) async throws -> [Int64] {
        let chats = try await td {
            try await client.searchPublicChats(query: query, typeFilter: nil)
        }
        return chats.chatIds
    }

    /// Global message search over every non-secret chat, reverse-chronological —
    /// Telegram's "Messages" section. TDLib chooses how many to actually return.
    public func searchMessages(query: String, limit: Int = 20) async throws -> [Message] {
        let found = try await td {
            try await client.searchMessages(
                chatList: nil,
                chatTypeFilter: nil,
                filter: nil,
                limit: limit,
                maxDate: 0,
                minDate: 0,
                offset: "",
                query: query)
        }
        return found.messages
    }

    // MARK: - Files

    /// Asynchronous by design: `synchronous: true` stalls the actor until the
    /// whole file lands. Progress and completion arrive as `updateFile`, which
    /// carries both download *and* upload progress.
    @discardableResult
    public func downloadFile(
        fileId: Int,
        priority: Int = 16,
        offset: Int64 = 0,
        limit: Int64 = 0,
        synchronous: Bool = false
    ) async throws -> File {
        try await td {
            try await client.downloadFile(
                fileId: fileId,
                limit: limit,
                offset: offset,
                priority: priority,
                synchronous: synchronous)
        }
    }
}
