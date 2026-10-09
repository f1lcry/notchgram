import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import os
@preconcurrency import TDLibKit

/// The open conversation.
///
/// Holds exactly one chat's window at a time — the panel shows one conversation,
/// and keeping every visited chat resident is how a background agent quietly
/// grows to a gigabyte.
///
/// Fed by the single ordered update stream, in order, on the main actor. Nothing
/// here spawns a `Task` per update.
///
/// **`items` is published in batches.** A history page holds up to 40 messages;
/// appending them one by one publishes 40 separate SwiftUI transactions, each of
/// which re-diffs the whole message list. That — measured, not theorised — is
/// what drove the main thread into a livelock at 13 GB: pages chained while the
/// pointer sat on the load spinner, and every single message triggered a full
/// re-layout of every platform text view in the list. All bulk mutations build a
/// local copy and assign once.
@MainActor
@Observable
public final class MessageRepo: TelegramUpdateSink {

    /// Live growth is capped: a chat left open under a busy channel would
    /// otherwise accumulate messages forever. Scroll-back past the cap is
    /// re-loadable, so dropping the oldest rows loses nothing.
    static let maxLiveItems = 1500
    /// Two `loadOlder` calls closer than this are one user gesture — the
    /// spinner re-appearing after a prepend must not chain-load the entire
    /// history.
    static let olderLoadCooldown: Duration = .milliseconds(300)

    /// Oldest first, which is the order a chat is read in.
    public private(set) var items: [MessageItem] = []

    /// An outgoing message is still on its way to the server — a file mid-
    /// upload, mostly. The panel pins itself open on this (Dictate's "latched
    /// while dictating"), so moving the pointer away during an upload does not
    /// fold the progress out of sight.
    public var hasPendingOutgoing: Bool {
        items.contains { $0.isOutgoing && $0.status == .pending }
    }
    public private(set) var chatId: Int64?
    public private(set) var isLoadingHistory = false
    /// False once TDLib has told us there is nothing older.
    public private(set) var hasMoreHistory = true
    /// True when the newest loaded row is NOT the chat's newest message — the
    /// window slid backwards past the cap (or opened mid-history), and the gap
    /// down to the live bottom is re-loadable via `loadNewer`. Setter is
    /// internal for the offline window tests.
    public internal(set) var hasMoreNewer = false

    /// Where a freshly opened chat should land.
    public enum OpenTarget: Equatable, Sendable {
        /// The newest message — a fully read chat.
        case latest
        /// Centred on a message id: the saved scroll position or the unread
        /// boundary.
        case around(Int64)
    }

    /// Increments when an open's initial history has landed — the view's cue
    /// to perform its one programmatic scroll to the open target.
    public private(set) var initialLoadGeneration = 0
    /// The unread boundary captured at open (the chat's
    /// `lastReadInboxMessageId` before this visit started marking things
    /// read). The view draws the "Unread messages" divider after it.
    public private(set) var unreadBoundary: Int64?
    public private(set) var lastError: TDError?
    /// Someone is typing, from `updateChatAction`.
    public private(set) var typingNames: [String] = []

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "MessageRepo")

    @ObservationIgnored private var keyByMessageId: [Int64: MessageKey] = [:]
    @ObservationIgnored private var indexByKey: [MessageKey: Int] = [:]
    @ObservationIgnored private var lastReadOutboxMessageId: Int64 = 0
    @ObservationIgnored private var userNames: [Int64: String] = [:]
    @ObservationIgnored private var userPhotoFileIds: [Int64: Int] = [:]
    @ObservationIgnored private var openedChatId: Int64?
    @ObservationIgnored private var lastOlderLoadEnded: ContinuousClock.Instant?
    @ObservationIgnored private var lastNewerLoadEnded: ContinuousClock.Instant?
    /// Incoming rows that have been on screen but not yet reported to
    /// `viewMessages`. Flushed in one debounced batch.
    @ObservationIgnored private var pendingSeen: Set<Int64> = []
    @ObservationIgnored private var seenFlushTask: Task<Void, Never>?

    /// True only while the panel is expanded **and** settled on a screen showing
    /// this conversation.
    ///
    /// It gates read receipts, and the choice is deliberate: `forceRead` tells
    /// Telegram the messages were seen, so tying it to "the panel is open" means
    /// a hover that happens to land on an open chat marks it read. Gating on
    /// `settled` — past the unfold spring — is the line between "the panel
    /// brushed past" and "it is on screen being read".
    public private(set) var isConversationVisible = false
    /// Which view instance last claimed visibility. One repo serves every
    /// screen's panel, and their view lifecycles overlap: moving the panel to
    /// another screen settles the new panel (450 ms) *before* the old one
    /// unmounts (700 ms), so the old view's `onDisappear` used to clear the
    /// flag the new view had just set — and the open conversation stopped
    /// sending read receipts entirely until the panel was re-expanded.
    @ObservationIgnored private var visibilityOwner: UUID?

    /// Claims (`visible == true`) or releases visibility on behalf of one view
    /// instance. A release from a view that is not the current owner is a
    /// stale lifecycle event and is ignored.
    public func setConversationVisible(_ visible: Bool, owner: UUID) {
        if visible {
            visibilityOwner = owner
            guard !isConversationVisible else { return }
            isConversationVisible = true
            scheduleSeenFlush()
        } else {
            guard visibilityOwner == owner else { return }
            visibilityOwner = nil
            isConversationVisible = false
        }
    }

    private weak var client: TDClient?

    /// The one path read receipts leave through — injectable so the offline
    /// tests can record what would be reported to `viewMessages`.
    @ObservationIgnored var viewMessagesSender: (@MainActor (Int64, [Int64]) async -> Void)?

    public init() {}

    public func attach(client: TDClient) {
        self.client = client
        viewMessagesSender = { [weak client] chatId, messageIds in
            try? await client?.viewMessages(
                chatId: chatId, messageIds: messageIds, forceRead: true)
        }
    }

    /// Small avatar file for a sender, once `updateUser` has been seen. Used by
    /// the grouped-message avatars in the conversation view.
    public func photoFileId(forUser userId: Int64) -> Int? {
        userPhotoFileIds[userId]
    }

    // MARK: - Opening and closing

    /// `openChat`/`closeChat` is not bookkeeping: in supergroups and channels
    /// TDLib delivers message updates **only for opened chats**, so without this
    /// bracket a busy group simply never updates live.
    public func open(
        chatId: Int64,
        target: OpenTarget = .latest,
        unreadBoundary: Int64? = nil
    ) async {
        guard self.chatId != chatId else { return }
        // Rows read in the outgoing chat during the last debounce window would
        // be silently dropped by the reset below — a chat visited for under
        // 300 ms stayed unread forever.
        flushPendingSeenNow()
        await closeCurrent()

        self.chatId = chatId
        items = []
        keyByMessageId = [:]
        indexByKey = [:]
        hasMoreHistory = true
        hasMoreNewer = false
        lastError = nil
        typingNames = []
        lastOlderLoadEnded = nil
        lastNewerLoadEnded = nil
        pendingSeen = []
        self.unreadBoundary = unreadBoundary

        guard let client else {
            #if DEBUG
            openOffline(chatId: chatId)
            #endif
            return
        }
        try? await client.openChat(chatId: chatId)
        openedChatId = chatId

        await loadInitialHistory(target: target)
    }

    #if DEBUG
    /// Demo mode only (no TDLib client exists): a chat's history as the
    /// updates TDLib would have delivered for it. The messages go through the
    /// same batch `merge` a history page takes; everything else (read markers,
    /// reactions) is applied as an ordinary update afterwards.
    @ObservationIgnored public var offlineHistory: (@MainActor (Int64) -> [Update])?

    private func openOffline(chatId: Int64) {
        guard let offlineHistory else { return }
        var messages: [Message] = []
        var rest: [Update] = []
        for update in offlineHistory(chatId) {
            if case .updateNewMessage(let payload) = update {
                messages.append(payload.message)
            } else {
                rest.append(update)
            }
        }
        merge(messages)
        for update in rest { apply(update) }
        hasMoreHistory = false
        initialLoadGeneration += 1
    }
    #endif

    public func closeCurrent() async {
        guard let openedChatId, let client else { return }
        try? await client.closeChat(chatId: openedChatId)
        self.openedChatId = nil
    }

    // MARK: - History

    /// Paints from the local cache first, then backfills from the server.
    ///
    /// The `only_local` pass is what makes reopening a chat instant instead of a
    /// blank rectangle for one network round trip.
    private func loadInitialHistory(target: OpenTarget = .latest) async {
        guard let client, let chatId else { return }
        isLoadingHistory = true

        switch target {
        case .latest:
            if let local = try? await client.chatHistory(
                chatId: chatId, limit: 40, onlyLocal: true), !local.isEmpty {
                merge(local)
            }
            isLoadingHistory = false
            await fetchOlder(limit: 40)

        case .around(let anchor):
            // Both sides of the anchor in one request; the anchor row itself
            // is included. The gap down to the live bottom becomes pageable.
            if let local = try? await client.chatHistory(
                chatId: chatId, fromMessageId: anchor, offset: -20, limit: 40,
                onlyLocal: true), !local.isEmpty {
                merge(local)
            }
            if let page = try? await client.chatHistory(
                chatId: chatId, fromMessageId: anchor, offset: -20, limit: 40) {
                merge(page)
            }
            hasMoreNewer = true
            isLoadingHistory = false
            // Pad above so the anchor is not the very first row on screen.
            await fetchOlder(limit: 20)
        }

        initialLoadGeneration += 1
    }

    /// One page older than what is held. Rate-limited: the load spinner's
    /// `onAppear` re-fires every time a prepend re-materialises it, and without
    /// a cooldown that chain-loads the entire history while the pointer rests
    /// at the top of the list.
    public func loadOlder(limit: Int = 40) async {
        if let ended = lastOlderLoadEnded,
           ContinuousClock.now - ended < Self.olderLoadCooldown { return }
        await fetchOlder(limit: limit)
    }

    /// **A loop, not a single call.** TDLib documents that the first
    /// `getChatHistory` on a cold cache returns 0–1 messages regardless of
    /// `limit`; a caller that trusts one response shows an almost-empty chat and
    /// concludes there is no more history. A response of 0 is the documented
    /// end-of-history signal.
    private func fetchOlder(limit: Int) async {
        guard let client, let chatId, hasMoreHistory, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer {
            isLoadingHistory = false
            lastOlderLoadEnded = ContinuousClock.now
        }

        var from = items.first?.messageId ?? 0
        var gained = 0

        for _ in 0..<10 {
            do {
                let page = try await client.chatHistory(
                    chatId: chatId, fromMessageId: from, offset: 0, limit: limit)
                if page.isEmpty {
                    hasMoreHistory = false
                    break
                }
                merge(page)
                gained += page.count
                from = page.map(\.id).min() ?? from
                if gained >= limit { break }
            } catch {
                lastError = TDError.wrap(error)
                log.error("getChatHistory failed: \(self.lastError?.message ?? "?", privacy: .public)")
                break
            }
        }
        trimNewestOverflow()
    }

    /// One page newer than what is held — the mirror of `loadOlder`, used when
    /// the window slid backwards past the cap (or opened at the unread mark)
    /// and the reader is scrolling back down toward the live bottom.
    public func loadNewer(limit: Int = 40) async {
        if let ended = lastNewerLoadEnded,
           ContinuousClock.now - ended < Self.olderLoadCooldown { return }
        await fetchNewer(limit: limit)
    }

    private func fetchNewer(limit: Int) async {
        guard let client, let chatId, hasMoreNewer, !isLoadingHistory,
              let newest = items.last(where: { $0.hasServerId })?.messageId
        else { return }
        isLoadingHistory = true
        defer {
            isLoadingHistory = false
            lastNewerLoadEnded = ContinuousClock.now
        }

        var from = newest
        var gained = 0

        for _ in 0..<10 {
            do {
                // `offset: -limit` asks for the messages *after* the anchor;
                // the anchor itself comes back too and is deduped by `merge`.
                let page = try await client.chatHistory(
                    chatId: chatId, fromMessageId: from, offset: -limit, limit: limit + 1)
                let fresh = page.filter { keyByMessageId[$0.id] == nil }
                if fresh.isEmpty {
                    hasMoreNewer = false
                    break
                }
                merge(fresh)
                gained += fresh.count
                from = page.map(\.id).max() ?? from
                if gained >= limit { break }
            } catch {
                lastError = TDError.wrap(error)
                log.error("getChatHistory(newer) failed: \(self.lastError?.message ?? "?", privacy: .public)")
                break
            }
        }
        trimLiveOverflow()
    }

    /// Drops the current window and reloads the chat's newest page — what the
    /// scroll-to-bottom button means once the window has slid off the live
    /// bottom.
    public func reloadLatest() async {
        guard chatId != nil else { return }
        items = []
        keyByMessageId = [:]
        indexByKey = [:]
        hasMoreHistory = true
        hasMoreNewer = false
        await loadInitialHistory()
    }

    /// A row reports itself when it lands on screen. Read receipts follow what
    /// was actually seen — opening at the unread divider must NOT mark the
    /// whole loaded window read the way Session 4's blanket pass did, or the
    /// divider lies and Telegram on the phone shows everything read.
    public func noteVisible(_ messageId: Int64) {
        guard messageId != 0,
              let key = keyByMessageId[messageId], let index = indexByKey[key],
              !items[index].isOutgoing
        else { return }
        pendingSeen.insert(messageId)
        if isConversationVisible { scheduleSeenFlush() }
    }

    private func scheduleSeenFlush() {
        guard seenFlushTask == nil else { return }
        seenFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.seenFlushTask = nil
            guard self.isConversationVisible, !self.pendingSeen.isEmpty,
                  let chatId = self.chatId else { return }
            let batch = Array(self.pendingSeen)
            self.pendingSeen = []
            await self.markRead(batch, in: chatId)
        }
    }

    /// Reports the pending batch immediately, without the debounce — the exit
    /// paths (switching chats, replying) where waiting 300 ms means the report
    /// is lost to the reset that follows.
    private func flushPendingSeenNow() {
        guard isConversationVisible, let chatId, !pendingSeen.isEmpty else { return }
        let batch = Array(pendingSeen)
        pendingSeen = []
        Task { [weak self] in await self?.markRead(batch, in: chatId) }
    }

    /// Replying claims the chat is read — Telegram's rule. The newest loaded
    /// incoming message is the watermark; TDLib marks everything at or below
    /// it read, so the badge cannot outlive the user's own answer.
    func markReadOnReply() {
        guard let chatId else { return }
        var batch = pendingSeen
        pendingSeen = []
        if let newest = items.last(where: { !$0.isOutgoing && $0.hasServerId })?.messageId {
            batch.insert(newest)
        }
        guard !batch.isEmpty else { return }
        Task { [weak self] in await self?.markRead(Array(batch), in: chatId) }
    }

    private func markRead(_ messageIds: [Int64], in chatId: Int64) async {
        guard !messageIds.isEmpty else { return }
        await viewMessagesSender?(chatId, messageIds)
    }

    // MARK: - Sending

    /// Optimistic send: the row appears immediately, keyed on the correlation
    /// token rather than on any id, and is reconciled when the server answers.
    public func sendText(_ text: String) async {
        guard let client, let chatId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Sending from deep scroll-back: re-anchor to the live bottom first
        // (Telegram jumps there on send), so the optimistic row and its echo
        // land in a window that actually contains the bottom.
        if hasMoreNewer { await reloadLatest() }
        markReadOnReply()

        let sendingId = TDClient.newSendingId()
        insertOptimistic(text: trimmed, sendingId: sendingId, chatId: chatId)

        do {
            let message = try await client.sendText(
                chatId: chatId, text: trimmed, sendingId: sendingId)
            // TDLib's local echo (`updateNewMessage`, pending state) can outrun
            // this response. `merge` recognises it by `sendingId` and folds it
            // into the optimistic row, but if anything still slipped in under
            // the temporary id, drop it — it is the same message, and the
            // duplicate it left behind stayed "sending" forever.
            if let stray = keyByMessageId[message.id], stray != .local(sendingId) {
                remove(stray)
            }
            // Bind the temporary id so `updateMessageSendSucceeded` finds the
            // row we already drew.
            bind(messageId: message.id, to: .local(sendingId))
            mutate(.local(sendingId)) { $0.messageId = message.id }
        } catch {
            let mapped = TDError.wrap(error)
            lastError = mapped
            mutate(.local(sendingId)) { $0.status = .failed(mapped.message) }
        }
    }

    /// Sends a file, choosing photo or document by what it actually is.
    ///
    /// A screenshot dropped on the panel should arrive as a photo; a PDF as a
    /// document. Deciding by UTI rather than by extension is what makes a
    /// pasted, extension-less temp file behave.
    public func sendFile(at url: URL, asDocument: Bool = false) async {
        guard let client, let chatId else { return }
        if hasMoreNewer { await reloadLatest() }
        markReadOnReply()
        let sendingId = TDClient.newSendingId()
        let isImage = !asDocument && Self.isRenderableImage(url)

        do {
            if isImage, let size = Self.imagePixelSize(url) {
                _ = try await client.sendPhoto(
                    chatId: chatId,
                    path: url.path,
                    width: size.width,
                    height: size.height,
                    sendingId: sendingId)
            } else {
                _ = try await client.sendDocument(
                    chatId: chatId, path: url.path, sendingId: sendingId)
            }
        } catch {
            lastError = TDError.wrap(error)
            log.error("send file failed: \(self.lastError?.message ?? "?", privacy: .public)")
        }
    }

    /// TDLib's photo limits: at most 10 MB, width + height ≤ 10000, ratio ≤ 20.
    /// Anything outside them is sent as a document rather than rejected.
    static func isRenderableImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image)
        else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 10 * 1024 * 1024 else { return false }
        guard let pixels = imagePixelSize(url) else { return false }
        guard pixels.width + pixels.height <= 10_000 else { return false }
        let ratio = Double(max(pixels.width, pixels.height))
            / Double(max(1, min(pixels.width, pixels.height)))
        return ratio <= 20
    }

    static func imagePixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// The optimistic row a send draws before the server answers. Internal so
    /// the update-sink tests can stage the send race without a live client.
    func insertOptimistic(text: String, sendingId: Int, chatId: Int64) {
        insert(MessageItem(
            id: .local(sendingId),
            messageId: 0,
            chatId: chatId,
            senderUserId: 0,
            senderName: "",
            isOutgoing: true,
            date: Int(Date().timeIntervalSince1970),
            content: .messageText(InputTextPreview.content(text)),
            status: .pending))
    }

    /// Asks Telegram to transcribe a voice/video note. The result arrives via
    /// `updateMessageContent` and re-renders the bubble on its own.
    public func transcribe(messageId: Int64) async {
        guard let client, let chatId else { return }
        await client.recognizeSpeech(chatId: chatId, messageId: messageId)
    }

    /// Re-sends a failed message. The failed row is dropped and a fresh
    /// optimistic one takes its place, so the retry is visible.
    public func retry(_ key: MessageKey) async {
        guard let index = indexByKey[key] else { return }
        let item = items[index]
        guard case .failed = item.status, let text = item.text else { return }
        remove(key)
        await sendText(text)
    }

    // MARK: - Update sink

    public func apply(_ update: Update) {
        switch update {
        case .updateNewMessage(let payload):
            guard payload.message.chatId == chatId else { break }
            // Detached from the live bottom (deep scroll-back): the new
            // message is not adjacent to the loaded window — appending it
            // would splice a gap into the middle of history. It loads when
            // the reader pages back down.
            guard !hasMoreNewer else { break }
            merge([payload.message])
            trimLiveOverflow()
            // No blanket mark-read here: a message arriving while the reader
            // is scrolled up inside the live window was being force-marked
            // read without ever being on screen. The row reports itself via
            // `noteVisible` when it actually materialises (the view also
            // notes it explicitly when glued to the bottom), so the receipt
            // follows what was seen.

        case .updateMessageSendSucceeded(let payload):
            guard payload.message.chatId == chatId else { break }
            // Replace the whole object: "almost any field can be different", so
            // patching the id would leave stale content behind. The row keeps
            // its key, so SwiftUI does not tear it down.
            let key = keyByMessageId[payload.oldMessageId] ?? .server(payload.oldMessageId)
            keyByMessageId.removeValue(forKey: payload.oldMessageId)
            keyByMessageId[payload.message.id] = key
            mutate(key) { item in
                let fresh = MessageItem(payload.message, senderName: item.senderName)
                item.messageId = fresh.messageId
                item.content = fresh.content
                item.date = fresh.date
                item.editDate = fresh.editDate
                item.status = .sent
                item.isReadByPeer = fresh.messageId <= self.lastReadOutboxMessageId
            }
            resort()

        case .updateMessageSendFailed(let payload):
            guard payload.message.chatId == chatId else { break }
            let key = keyByMessageId[payload.oldMessageId] ?? .server(payload.oldMessageId)
            mutate(key) { $0.status = .failed(payload.error.message) }

        case .updateMessageContent(let payload):
            guard payload.chatId == chatId, let key = keyByMessageId[payload.messageId] else { break }
            mutate(key) { $0.content = payload.newContent }

        case .updateMessageEdited(let payload):
            guard payload.chatId == chatId, let key = keyByMessageId[payload.messageId] else { break }
            mutate(key) { $0.editDate = payload.editDate }

        case .updateMessageInteractionInfo(let payload):
            guard payload.chatId == chatId, let key = keyByMessageId[payload.messageId] else { break }
            let chips = MessageReactionChip.chips(from: payload.interactionInfo)
            mutate(key) { $0.reactions = chips }

        case .updateDeleteMessages(let payload):
            guard payload.chatId == chatId else { break }
            // `from_cache` means cache eviction, not deletion — the message can
            // come back. Only `is_permanent` is a real delete.
            guard payload.isPermanent, !payload.fromCache else { break }
            for messageId in payload.messageIds {
                if let key = keyByMessageId[messageId] { remove(key) }
            }

        case .updateChatReadOutbox(let payload):
            guard payload.chatId == chatId else { break }
            lastReadOutboxMessageId = payload.lastReadOutboxMessageId
            // There is no per-message read update; every visible outgoing row
            // has to be re-evaluated when the marker moves.
            var working = items
            var changed = false
            for index in working.indices where working[index].isOutgoing {
                let read = working[index].messageId <= payload.lastReadOutboxMessageId
                if working[index].isReadByPeer != read {
                    working[index].isReadByPeer = read
                    changed = true
                }
            }
            if changed { items = working }

        case .updateChatAction(let payload):
            guard payload.chatId == chatId else { break }
            applyTypingAction(payload)

        case .updateUser(let payload):
            let name = "\(payload.user.firstName) \(payload.user.lastName)"
                .trimmingCharacters(in: .whitespaces)
            userNames[payload.user.id] = name
            userPhotoFileIds[payload.user.id] = payload.user.profilePhoto?.small.id
            var working = items
            var changed = false
            for index in working.indices where working[index].senderUserId == payload.user.id {
                if working[index].senderName != name {
                    working[index].senderName = name
                    changed = true
                }
            }
            if changed { items = working }

        default:
            break
        }
    }

    /// `updateUserChatAction` does not exist in 1.8.66 — it is `updateChatAction`
    /// with a `senderId`.
    private func applyTypingAction(_ payload: UpdateChatAction) {
        guard case .messageSenderUser(let sender) = payload.senderId else { return }
        let name = userNames[sender.userId] ?? "Someone"
        switch payload.action {
        case .chatActionCancel:
            typingNames.removeAll { $0 == name }
        default:
            if !typingNames.contains(name) { typingNames.append(name) }
        }
    }

    // MARK: - Window maintenance

    /// The history-page ingestion path (`fetchOlder`/`fetchNewer` route their
    /// pages through `merge`), exposed so the offline window tests can stage a
    /// page without a live client.
    func ingest(_ messages: [Message]) {
        merge(messages)
    }

    /// Batch merge: builds the new window locally and publishes **once**.
    private func merge(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        var working = items

        for message in messages {
            let name = senderName(of: message)
            if let key = keyByMessageId[message.id], let index = indexByKey[key] {
                var item = working[index]
                item.content = message.content
                item.editDate = message.editDate
                item.senderName = name
                item.reactions = MessageReactionChip.chips(from: message.interactionInfo)
                working[index] = item
                continue
            }
            // Our own send, echoed back by TDLib before the `sendMessage`
            // response has bound its temporary id: the id is unknown here, but
            // the pending state carries the correlation token. Fold the echo
            // into the optimistic row instead of inserting — inserting is what
            // duplicated outgoing messages (one row stuck on the clock, one
            // confirmed) until the chat was reopened.
            if message.isOutgoing,
               case .messageSendingStatePending(let pending) = message.sendingState,
               let index = indexByKey[.local(pending.sendingId)] {
                keyByMessageId[message.id] = .local(pending.sendingId)
                var item = working[index]
                item.messageId = message.id
                item.content = message.content
                item.date = message.date
                item.editDate = message.editDate
                working[index] = item
                continue
            }
            var item = MessageItem(message, senderName: name)
            item.isReadByPeer = message.id <= lastReadOutboxMessageId
            keyByMessageId[message.id] = item.id
            working.append(item)
            indexByKey[item.id] = working.count - 1
        }

        working.sort(by: Self.chronological)
        if working != items { items = working }
        reindex()
    }

    /// Drops the oldest rows once growth passes the cap — the live-append and
    /// page-newer paths, where the reader is at or moving toward the bottom
    /// and the top of the window is far off screen.
    private func trimLiveOverflow() {
        let overflow = items.count - Self.maxLiveItems
        guard overflow > 0 else { return }
        let dropped = items.prefix(overflow)
        items.removeFirst(overflow)
        for item in dropped where item.messageId != 0 {
            keyByMessageId.removeValue(forKey: item.messageId)
        }
        hasMoreHistory = true
        reindex()
    }

    /// The mirror: scroll-back drops the *newest* rows, which are the ones far
    /// below the viewport. Session 4 never trimmed this path at all — deep
    /// scroll-back grew `items` (and its minithumbnail payloads) without
    /// bound, which is the fast-scroll crash. Rows still in flight are never
    /// dropped; the trim just waits for the next pass. Internal for tests.
    func trimNewestOverflow() {
        let overflow = items.count - Self.maxLiveItems
        guard overflow > 0 else { return }
        let dropped = items.suffix(overflow)
        guard dropped.allSatisfy({ $0.hasServerId && $0.status != .pending }) else { return }
        items.removeLast(overflow)
        for item in dropped {
            keyByMessageId.removeValue(forKey: item.messageId)
        }
        hasMoreNewer = true
        reindex()
    }

    private func senderName(of message: Message) -> String {
        guard case .messageSenderUser(let sender) = message.senderId else { return "" }
        return userNames[sender.userId] ?? ""
    }

    private func insert(_ item: MessageItem) {
        items.append(item)
        reindex()
    }

    private func mutate(_ key: MessageKey, _ body: (inout MessageItem) -> Void) {
        guard let index = indexByKey[key] else { return }
        body(&items[index])
    }

    private func remove(_ key: MessageKey) {
        guard let index = indexByKey[key] else { return }
        let removed = items.remove(at: index)
        keyByMessageId.removeValue(forKey: removed.messageId)
        reindex()
    }

    /// Oldest first, ties broken by id so the order is total. Messages that have
    /// no server id yet (still sending) sort last, which is where they belong.
    private static func chronological(_ lhs: MessageItem, _ rhs: MessageItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.messageId < rhs.messageId
    }

    private func resort() {
        var working = items
        working.sort(by: Self.chronological)
        if working != items { items = working }
        reindex()
    }

    private func reindex() {
        indexByKey = [:]
        for (index, item) in items.enumerated() { indexByKey[item.id] = index }
    }

    private func bind(messageId: Int64, to key: MessageKey) {
        keyByMessageId[messageId] = key
    }
}

/// Builds the `messageText` content an optimistic row renders before the server
/// has echoed anything back.
enum InputTextPreview {
    static func content(_ text: String) -> MessageText {
        MessageText(
            linkPreview: nil,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: text))
    }
}
