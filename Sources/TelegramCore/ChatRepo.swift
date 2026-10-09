import Foundation
import Observation
import os
@preconcurrency import TDLibKit

/// NotchGram's mutable picture of one chat.
///
/// TDLibKit's `Chat` is entirely `let`, so patching it in place is impossible —
/// and patching is exactly what the update stream does: `updateChatTitle`,
/// `updateChatReadInbox` and a dozen siblings each carry one field, not a whole
/// chat. Mapping to our own model at the boundary is what the architecture calls
/// for anyway; the compiler simply insists on it.
struct ChatState {
    var id: Int64
    var title: String
    var type: ChatType
    var lastMessage: Message?
    var draftText: String?
    var unreadCount: Int
    var unreadMentionCount: Int
    var lastReadInboxMessageId: Int64
    var lastReadOutboxMessageId: Int64
    var isMarkedAsUnread: Bool
    var notificationSettings: ChatNotificationSettings
    var photoSmallFileId: Int?
    var photoMinithumbnail: Data?
    /// Default member permissions. For the *current user's* ability to post,
    /// combine with the member status delivered by `updateSupergroup`.
    var permissions: ChatPermissions
    var supergroupId: Int64?

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title
        type = chat.type
        lastMessage = chat.lastMessage
        draftText = Self.draftText(chat.draftMessage)
        unreadCount = chat.unreadCount
        unreadMentionCount = chat.unreadMentionCount
        lastReadInboxMessageId = chat.lastReadInboxMessageId
        lastReadOutboxMessageId = chat.lastReadOutboxMessageId
        isMarkedAsUnread = chat.isMarkedAsUnread
        notificationSettings = chat.notificationSettings
        photoSmallFileId = chat.photo?.small.id
        photoMinithumbnail = chat.photo?.minithumbnail?.data
        permissions = chat.permissions
        if case .chatTypeSupergroup(let value) = chat.type {
            supergroupId = value.supergroupId
        }
    }

    static func draftText(_ draft: DraftMessage?) -> String? {
        guard let draft, case .draftMessageContentText(let content) = draft.content else {
            return nil
        }
        let text = content.text.text
        return text.isEmpty ? nil : text
    }
}

/// The chat list.
///
/// Fed by the single ordered update stream, in order, on the main actor — see
/// `TelegramUpdateSink`. Nothing here spawns a `Task` to do its work: TDLib
/// requires updates to be handled in the order received, and per-update tasks
/// silently reorder them, which corrupts chat order and unread counters in ways
/// that look random and reproduce on nobody's machine.
@MainActor
@Observable
public final class ChatRepo: TelegramUpdateSink {

    /// Rows in display order: pinned first, then by TDLib's order descending.
    public private(set) var chats: [ChatSummary] = []
    public private(set) var totalUnreadCount = 0
    public private(set) var totalUnreadChatCount = 0
    /// True until the first page has arrived, so the UI can tell "empty because
    /// loading" from "empty because there is nothing".
    public private(set) var isLoading = true

    /// Set once `getMe` lands, so a private chat with oneself renders as Saved
    /// Messages rather than as a contact.
    public var myUserId: Int64? {
        didSet { invalidateAll(); rebuildIfNeeded() }
    }

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "ChatRepo")

    /// Entities are cached from updates, never fetched. TDLib guarantees
    /// `updateNewChat` / `updateUser` arrive **before** the id is handed to the
    /// application, so calling `getChat`/`getUser` to resolve an id is both
    /// unnecessary and a round trip in the middle of rendering.
    private var chatStates: [Int64: ChatState] = [:]
    private var userNames: [Int64: String] = [:]
    private var botUserIds: Set<Int64> = []
    /// Our own member status per supergroup/channel, from `updateSupergroup`.
    /// This is what decides whether the composer is shown in a channel.
    private var supergroupStatuses: [Int64: ChatMemberStatus] = [:]
    private var scopeMuteFor: [String: Int] = [:]
    private var index = ChatOrderIndex(list: .chatListMain)
    private var needsRebuild = false
    /// Rendered rows, kept per chat.
    ///
    /// First sync is a burst of hundreds of `updateNewChat` and position
    /// updates, and re-mapping every chat on every one of them is O(chats²) at
    /// exactly the moment the client is being judged on cold-start time. Only
    /// the chats an update actually touched are re-summarised.
    private var summaryCache: [Int64: ChatSummary] = [:]
    private var dirtyChatIds: Set<Int64> = []

    private weak var client: TDClient?

    public init() {}

    public func attach(client: TDClient) {
        self.client = client
    }

    // MARK: - Loading

    /// Asks TDLib for more of the main list. The chats themselves arrive as
    /// updates; this only moves the window. A 404 is the documented
    /// end-of-list signal, not a failure.
    public func loadMore(limit: Int = 40) async {
        guard let client else { return }
        do {
            try await client.loadChats(chatList: .chatListMain, limit: limit)
        } catch let error as TDError where error.isNotFound {
            log.debug("chat list fully loaded")
        } catch {
            log.error("loadChats failed: \(TDError.wrap(error).message, privacy: .public)")
        }
        isLoading = false
    }

    /// Rows for an explicit id order — how a folder tab renders, reusing the
    /// same summaries the main list already built.
    public func summaries(for ids: [Int64]) -> [ChatSummary] {
        ids.compactMap { summaryCache[$0] }
    }

    /// One cached row by id, regardless of which list (if any) the chat sits
    /// in. TDLib sends `updateNewChat` for every chat id it returns from a
    /// request, so by the time a search response lands its ids resolve here —
    /// including chats that were never in the visible list.
    public func cachedSummary(id: Int64) -> ChatSummary? { summaryCache[id] }

    // MARK: - Update sink

    public func apply(_ update: Update) {
        switch update {
        case .updateNewChat(let payload):
            chatStates[payload.chat.id] = ChatState(payload.chat)
            applyPositions(chatId: payload.chat.id, positions: payload.chat.positions)

        case .updateChatPosition(let payload):
            applyPositions(chatId: payload.chatId, positions: [payload.position])

        // TDLib may send these **instead of** `updateChatPosition`, each with
        // its own positions array. Routing them anywhere else is how a chat that
        // just received a message fails to move to the top.
        case .updateChatLastMessage(let payload):
            mutate(payload.chatId) { state in
                // `last_message == nil` here means a *gap*, not an empty chat:
                // the tail needs refetching rather than clearing.
                if let message = payload.lastMessage { state.lastMessage = message }
            }
            applyPositions(chatId: payload.chatId, positions: payload.positions)

        case .updateChatDraftMessage(let payload):
            mutate(payload.chatId) { $0.draftText = ChatState.draftText(payload.draftMessage) }
            applyPositions(chatId: payload.chatId, positions: payload.positions)

        case .updateChatTitle(let payload):
            mutate(payload.chatId) { $0.title = payload.title }

        case .updateChatPhoto(let payload):
            mutate(payload.chatId) {
                $0.photoSmallFileId = payload.photo?.small.id
                $0.photoMinithumbnail = payload.photo?.minithumbnail?.data
            }

        case .updateChatReadInbox(let payload):
            mutate(payload.chatId) {
                $0.unreadCount = payload.unreadCount
                $0.lastReadInboxMessageId = payload.lastReadInboxMessageId
            }

        case .updateChatReadOutbox(let payload):
            mutate(payload.chatId) { $0.lastReadOutboxMessageId = payload.lastReadOutboxMessageId }

        case .updateChatUnreadMentionCount(let payload):
            mutate(payload.chatId) { $0.unreadMentionCount = payload.unreadMentionCount }

        case .updateChatNotificationSettings(let payload):
            mutate(payload.chatId) { $0.notificationSettings = payload.notificationSettings }

        case .updateScopeNotificationSettings(let payload):
            applyScopeSettings(payload.scope, payload.notificationSettings)

        case .updateChatIsMarkedAsUnread(let payload):
            mutate(payload.chatId) { $0.isMarkedAsUnread = payload.isMarkedAsUnread }

        case .updateChatPermissions(let payload):
            mutate(payload.chatId) { $0.permissions = payload.permissions }

        case .updateSupergroup(let payload):
            supergroupStatuses[payload.supergroup.id] = payload.supergroup.status
            for (id, state) in chatStates where state.supergroupId == payload.supergroup.id {
                invalidate(id)
            }

        case .updateUnreadChatCount(let payload):
            guard payload.chatList == .chatListMain else { break }
            totalUnreadChatCount = payload.unreadUnmutedCount

        case .updateUnreadMessageCount(let payload):
            guard payload.chatList == .chatListMain else { break }
            totalUnreadCount = payload.unreadUnmutedCount

        case .updateNewMessage(let payload):
            // The accompanying position update does the reordering; this only
            // keeps the preview honest when TDLib sends the message first.
            mutate(payload.message.chatId) { state in
                if (state.lastMessage?.id ?? 0) < payload.message.id {
                    state.lastMessage = payload.message
                }
            }

        case .updateMessageSendSucceeded(let payload):
            mutate(payload.message.chatId) { state in
                if state.lastMessage?.id == payload.oldMessageId {
                    // Replace the whole object: "almost any field can be
                    // different", so patching the id would leave stale content.
                    state.lastMessage = payload.message
                }
            }

        case .updateUser(let payload):
            let name = "\(payload.user.firstName) \(payload.user.lastName)"
                .trimmingCharacters(in: .whitespaces)
            userNames[payload.user.id] = name
            if case .userTypeBot = payload.user.type { botUserIds.insert(payload.user.id) }
            // A private chat's title is the user's name, so it must re-render;
            // so must any group whose preview carries this sender's prefix.
            if chatStates[payload.user.id] != nil { invalidate(payload.user.id) }
            for (id, state) in chatStates
            where state.lastMessage?.senderId == .messageSenderUser(
                MessageSenderUser(userId: payload.user.id)) {
                invalidate(id)
            }

        case .updateFile(let payload):
            // An avatar finishing its download changes what a row draws.
            // Completion only: progress ticks arrive at network speed and a
            // row re-render per tick is exactly the churn D-perf forbids.
            guard payload.file.local.isDownloadingCompleted else { break }
            for chat in chats where chat.photoFileId == payload.file.id {
                invalidate(chat.id)
            }

        default:
            break
        }

        rebuildIfNeeded()
    }

    // MARK: - Internals

    private func mutate(_ chatId: Int64, _ body: (inout ChatState) -> Void) {
        guard var state = chatStates[chatId] else { return }
        body(&state)
        chatStates[chatId] = state
        invalidate(chatId)
    }

    private func applyPositions(chatId: Int64, positions: [ChatPosition]) {
        index.apply(chatId: chatId, positions: positions)
        // The pinned flag lives on the position, so a reorder changes the row
        // itself, not just where it sits.
        invalidate(chatId)
    }

    private func invalidate(_ chatId: Int64) {
        dirtyChatIds.insert(chatId)
        needsRebuild = true
    }

    /// For the two things that change how *every* row renders: learning our own
    /// user id (Saved Messages) and a scope-wide mute change.
    private func invalidateAll() {
        dirtyChatIds.formUnion(chatStates.keys)
        needsRebuild = true
    }

    private func rebuildIfNeeded() {
        guard needsRebuild else { return }
        needsRebuild = false

        for id in dirtyChatIds {
            if let state = chatStates[id] {
                summaryCache[id] = summary(for: state)
            } else {
                summaryCache.removeValue(forKey: id)
            }
        }
        dirtyChatIds.removeAll()

        let rebuilt = index.orderedChatIds.compactMap { summaryCache[$0] }
        // Assigning an identical array still invalidates every SwiftUI row that
        // observes it; comparing values is far cheaper than re-rendering.
        if rebuilt != chats { chats = rebuilt }
        isLoading = false
    }

    func summary(for state: ChatState) -> ChatSummary {
        let kind = kind(of: state)
        let title = displayTitle(for: state, kind: kind)
        let position = index.position(of: state.id)

        var preview = ""
        var date = 0
        var showsUnreadTicks = false
        var showsReadTicks = false

        if let message = state.lastMessage {
            date = message.date
            let body = MessagePreview.text(for: message.content, language: .system)
            // Only groups get a sender prefix; a private chat has exactly two
            // participants and the prefix is noise.
            if kind == .basicGroup || kind == .supergroup || kind == .channel,
               !message.isOutgoing,
               case .messageSenderUser(let sender) = message.senderId,
               let name = userNames[sender.userId], !name.isEmpty {
                preview = "\(name): \(body)"
            } else {
                preview = body
            }
            if message.isOutgoing {
                // There is no per-message read update; ticks are derived by
                // comparing against the chat's last-read-outbox id.
                showsReadTicks = message.id <= state.lastReadOutboxMessageId
                showsUnreadTicks = !showsReadTicks
            }
        }

        if let draft = state.draftText {
            preview = draft.replacingOccurrences(of: "\n", with: " ")
        }

        return ChatSummary(
            id: state.id,
            title: title,
            kind: kind,
            preview: preview,
            date: date,
            unreadCount: state.unreadCount,
            unreadMentionCount: state.unreadMentionCount,
            isPinned: position?.isPinned ?? false,
            isMuted: isMuted(state),
            isMarkedAsUnread: state.isMarkedAsUnread,
            showsUnreadTicks: showsUnreadTicks,
            showsReadTicks: showsReadTicks,
            photoFileId: state.photoSmallFileId,
            minithumbnail: state.photoMinithumbnail,
            initials: initials(from: title),
            hasDraft: state.draftText != nil,
            canSendMessages: canSendMessages(state, kind: kind),
            lastReadInboxMessageId: state.lastReadInboxMessageId,
            lastMessageId: state.lastMessage?.id ?? 0)
    }

    /// Whether the composer belongs in this chat at all.
    ///
    /// Channels: only the creator or an admin with `canPostMessages`. Groups:
    /// the chat's default permissions, tightened by a restricted member status.
    /// Private chats and bots: always.
    private func canSendMessages(_ state: ChatState, kind: ChatSummary.Kind) -> Bool {
        switch kind {
        case .savedMessages, .privateChat, .bot, .secret, .unknown:
            return true
        case .channel:
            guard let supergroupId = state.supergroupId,
                  let status = supergroupStatuses[supergroupId]
            else { return false }
            switch status {
            case .chatMemberStatusCreator(let creator): return creator.isMember
            case .chatMemberStatusAdministrator(let admin): return admin.rights.canPostMessages
            default: return false
            }
        case .basicGroup, .supergroup:
            if let supergroupId = state.supergroupId,
               let status = supergroupStatuses[supergroupId] {
                switch status {
                case .chatMemberStatusRestricted(let restricted):
                    return restricted.permissions.canSendBasicMessages
                case .chatMemberStatusBanned, .chatMemberStatusLeft:
                    return false
                default:
                    break
                }
            }
            return state.permissions.canSendBasicMessages
        }
    }

    /// Flips the chat's mute state. Optimistic: the local row updates at once,
    /// and TDLib's confirming `updateChatNotificationSettings` is idempotent
    /// over it.
    public func toggleMute(chatId: Int64) async {
        guard let client, let state = chatStates[chatId] else { return }
        let old = state.notificationSettings
        let settings = ChatNotificationSettings(
            disableMentionNotifications: old.disableMentionNotifications,
            disablePinnedMessageNotifications: old.disablePinnedMessageNotifications,
            muteFor: isMuted(state) ? 0 : 2_147_483_647,
            muteStories: old.muteStories,
            showPreview: old.showPreview,
            showStoryPoster: old.showStoryPoster,
            soundId: old.soundId,
            storySoundId: old.storySoundId,
            useDefaultDisableMentionNotifications: old.useDefaultDisableMentionNotifications,
            useDefaultDisablePinnedMessageNotifications: old.useDefaultDisablePinnedMessageNotifications,
            useDefaultMuteFor: false,
            useDefaultMuteStories: old.useDefaultMuteStories,
            useDefaultShowPreview: old.useDefaultShowPreview,
            useDefaultShowStoryPoster: old.useDefaultShowStoryPoster,
            useDefaultSound: old.useDefaultSound,
            useDefaultStorySound: old.useDefaultStorySound)
        mutate(chatId) { $0.notificationSettings = settings }
        rebuildIfNeeded()
        do {
            try await client.setChatNotificationSettings(chatId: chatId, settings: settings)
        } catch {
            // Roll back on rejection; the server's view wins.
            mutate(chatId) { $0.notificationSettings = old }
            rebuildIfNeeded()
            log.error("toggleMute failed: \(TDError.wrap(error).message, privacy: .public)")
        }
    }

    private func kind(of state: ChatState) -> ChatSummary.Kind {
        switch state.type {
        case .chatTypePrivate(let value):
            if value.userId == myUserId { return .savedMessages }
            if botUserIds.contains(value.userId) { return .bot }
            return .privateChat
        case .chatTypeBasicGroup: return .basicGroup
        case .chatTypeSupergroup(let value): return value.isChannel ? .channel : .supergroup
        case .chatTypeSecret: return .secret
        }
    }

    private func displayTitle(for state: ChatState, kind: ChatSummary.Kind) -> String {
        if kind == .savedMessages { return "Saved Messages" }
        if state.title.isEmpty, case .chatTypePrivate(let value) = state.type,
           let name = userNames[value.userId], !name.isEmpty {
            return name
        }
        return state.title
    }

    /// `use_default_mute_for` makes `mute_for` meaningless on its own. A reader
    /// that trusts `mute_for` alone notifies for muted chats — this resolves
    /// against the scope defaults instead.
    private func isMuted(_ state: ChatState) -> Bool {
        state.notificationSettings.useDefaultMuteFor
            ? scopeMute(for: state) > 0
            : state.notificationSettings.muteFor > 0
    }

    private func scopeMute(for state: ChatState) -> Int {
        scopeMuteFor[scopeKey(for: state.type)] ?? 0
    }

    private func scopeKey(for type: ChatType) -> String {
        switch type {
        case .chatTypePrivate, .chatTypeSecret: "private"
        case .chatTypeBasicGroup: "group"
        case .chatTypeSupergroup(let value): value.isChannel ? "channel" : "group"
        }
    }

    func applyScopeSettings(
        _ scope: NotificationSettingsScope,
        _ settings: ScopeNotificationSettings
    ) {
        switch scope {
        case .notificationSettingsScopePrivateChats: scopeMuteFor["private"] = settings.muteFor
        case .notificationSettingsScopeGroupChats: scopeMuteFor["group"] = settings.muteFor
        case .notificationSettingsScopeChannelChats: scopeMuteFor["channel"] = settings.muteFor
        }
        invalidateAll()
    }

    private func initials(from title: String) -> String {
        let words = title.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
