import Foundation
@preconcurrency import TDLibKit

/// What a chat-list row needs, as a value type.
///
/// The UI never touches `TDLibKit.Chat` directly: those are non-Sendable
/// reference-shaped models from a package with zero concurrency annotations, and
/// mapping at the repo boundary is what keeps SwiftUI's diffing honest —
/// `Equatable` here means "this row actually changed".
public struct ChatSummary: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case savedMessages, privateChat, bot, basicGroup, supergroup, channel, secret, unknown
    }

    public let id: Int64
    public var title: String
    public var kind: Kind
    /// One line of preview. Already includes the sender prefix in a group.
    public var preview: String
    /// Unix timestamp of the last message, 0 when the chat has none.
    public var date: Int
    public var unreadCount: Int
    public var unreadMentionCount: Int
    public var isPinned: Bool
    public var isMuted: Bool
    public var isMarkedAsUnread: Bool
    /// The last message is ours and has not been read by the other side yet.
    public var showsUnreadTicks: Bool
    /// The last message is ours and *has* been read.
    public var showsReadTicks: Bool
    /// Avatar file, once TDLib has told us about one.
    public var photoFileId: Int?
    /// Inline JPEG bytes TDLib ships with the chat — the zero-latency avatar,
    /// shown while the real file downloads.
    public var minithumbnail: Data?
    /// Fallback monogram.
    public var initials: String
    /// A draft is in progress in this chat.
    public var hasDraft: Bool
    /// Whether the composer belongs in this chat. False for channels the user
    /// cannot post to and for groups where sending is restricted.
    public var canSendMessages: Bool
    /// The unread boundary: the newest incoming message the user has read.
    /// Opening the chat jumps to the first message after this, like Telegram.
    public var lastReadInboxMessageId: Int64
    /// Id of the chat's newest message, 0 when it has none.
    public var lastMessageId: Int64

    public init(
        id: Int64,
        title: String,
        kind: Kind,
        preview: String,
        date: Int,
        unreadCount: Int = 0,
        unreadMentionCount: Int = 0,
        isPinned: Bool = false,
        isMuted: Bool = false,
        isMarkedAsUnread: Bool = false,
        showsUnreadTicks: Bool = false,
        showsReadTicks: Bool = false,
        photoFileId: Int? = nil,
        minithumbnail: Data? = nil,
        initials: String = "",
        hasDraft: Bool = false,
        canSendMessages: Bool = true,
        lastReadInboxMessageId: Int64 = 0,
        lastMessageId: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.preview = preview
        self.date = date
        self.unreadCount = unreadCount
        self.unreadMentionCount = unreadMentionCount
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isMarkedAsUnread = isMarkedAsUnread
        self.showsUnreadTicks = showsUnreadTicks
        self.showsReadTicks = showsReadTicks
        self.photoFileId = photoFileId
        self.minithumbnail = minithumbnail
        self.initials = initials
        self.hasDraft = hasDraft
        self.canSendMessages = canSendMessages
        self.lastReadInboxMessageId = lastReadInboxMessageId
        self.lastMessageId = lastMessageId
    }

    /// The message the chat should open at: the unread boundary when there is
    /// something unread past it, else nil (open at the bottom).
    public var firstUnreadAnchor: Int64? {
        guard unreadCount > 0, lastReadInboxMessageId > 0,
              lastReadInboxMessageId < lastMessageId
        else { return nil }
        return lastReadInboxMessageId
    }

    /// True when the row should show a badge at all. A muted chat with unread
    /// messages still shows a count, just a grey one — same as Telegram.
    public var hasUnread: Bool { unreadCount > 0 || isMarkedAsUnread }
}

/// Preview and service-line language. `.en` is the default so tests stay
/// deterministic; the UI passes `.system`, which follows the user's locale —
/// the first thing a Russian-speaking founder noticed in Session 1 was
/// "Photo" beside Cyrillic messages.
public enum PreviewLanguage: Sendable {
    case en, ru

    /// Resolution order: an explicit `AppLanguage` choice ("ru" / "en", set by
    /// the Settings language buttons), otherwise the system's preferred
    /// languages — Russian when the first one is Russian, English for
    /// everyone else. A public build follows the user's Mac (amends D35, whose
    /// Russian fallback suited a single-user build); a Russian speaker
    /// whose macOS runs in English picks Russian once in Settings, or
    /// `defaults write com.f1lcry.notchgram AppLanguage ru`.
    public static var system: PreviewLanguage {
        resolve(
            appLanguage: UserDefaults.standard.string(forKey: "AppLanguage"),
            preferredLanguages: Locale.preferredLanguages)
    }

    /// The pure part of `system`, so the policy is unit-testable.
    public static func resolve(
        appLanguage: String?, preferredLanguages: [String]
    ) -> PreviewLanguage {
        switch appLanguage {
        case "en": .en
        case "ru": .ru
        // nil, "system" (an older explicit setting) or anything unknown.
        default: preferredLanguages.first?.lowercased().hasPrefix("ru") == true ? .ru : .en
        }
    }
}

/// One-line descriptions of message content, as Telegram writes them in a chat
/// list.
public enum MessagePreview {

    /// The preview line for a chat row. `senderName` is prefixed in group chats
    /// only, which is why the caller decides it rather than this function.
    public static func text(
        for content: MessageContent,
        language: PreviewLanguage = .en
    ) -> String {
        let ru = language == .ru
        switch content {
        case .messageText(let value):
            return value.text.text.replacingOccurrences(of: "\n", with: " ")
        case .messagePhoto(let value):
            return decorate("🖼", ru ? "Фото" : "Photo", value.caption.text)
        case .messageVideo(let value):
            return decorate("🎬", ru ? "Видео" : "Video", value.caption.text)
        case .messageAnimation(let value):
            return decorate("🎞", "GIF", value.caption.text)
        case .messageSticker(let value):
            let label = ru ? "Стикер" : "Sticker"
            let emoji = value.sticker.emoji
            return emoji.isEmpty ? label : "\(emoji) \(label)"
        case .messageVoiceNote(let value):
            return decorate("🎤", ru ? "Голосовое сообщение" : "Voice message", value.caption.text)
        case .messageVideoNote:
            return ru ? "📹 Видеосообщение" : "📹 Video message"
        case .messageAudio(let value):
            let title = value.audio.title
            return title.isEmpty ? (ru ? "🎵 Аудио" : "🎵 Audio") : "🎵 \(title)"
        case .messageDocument(let value):
            let name = value.document.fileName
            return name.isEmpty ? (ru ? "📎 Файл" : "📎 File") : "📎 \(name)"
        case .messageLocation:
            return ru ? "📍 Геопозиция" : "📍 Location"
        case .messageVenue(let value):
            return "📍 \(value.venue.title)"
        case .messageContact:
            return ru ? "👤 Контакт" : "👤 Contact"
        case .messagePoll(let value):
            return "📊 \(value.poll.question.text)"
        case .messageDice(let value):
            return value.emoji
        case .messageCall:
            return ru ? "📞 Звонок" : "📞 Call"
        case .messageAnimatedEmoji(let value):
            return value.emoji
        case .messageChatChangeTitle(let value):
            return ru ? "Название изменено на «\(value.title)»" : "Chat renamed to “\(value.title)”"
        case .messageChatAddMembers:
            return ru ? "Участники добавлены" : "Members added"
        case .messageChatDeleteMember:
            return ru ? "Участник удалён" : "Member removed"
        case .messagePinMessage:
            return ru ? "Закреплено сообщение" : "Pinned a message"
        case .messageChatJoinByLink, .messageChatJoinByRequest:
            return ru ? "Вступление в чат" : "Joined the chat"
        case .messageChatDeletePhoto:
            return ru ? "Фото чата удалено" : "Chat photo removed"
        case .messageChatChangePhoto:
            return ru ? "Фото чата обновлено" : "Chat photo changed"
        case .messageScreenshotTaken:
            return ru ? "Сделан скриншот" : "Screenshot taken"
        case .messageContactRegistered:
            return ru ? "Зарегистрирован(а) в Telegram" : "Joined Telegram"
        case .messageExpiredPhoto:
            return ru ? "Просроченное фото" : "Expired photo"
        case .messageExpiredVideo:
            return ru ? "Просроченное видео" : "Expired video"
        case .messageUnsupported:
            return ru ? "Неподдерживаемое сообщение" : "Unsupported message"
        default:
            // 100+ content cases exist and TDLib adds more every release. A
            // readable fallback beats an empty row.
            return ru ? "Сообщение" : "Message"
        }
    }

    private static func decorate(_ symbol: String, _ label: String, _ caption: String) -> String {
        caption.isEmpty
            ? "\(symbol) \(label)"
            : "\(symbol) \(caption.replacingOccurrences(of: "\n", with: " "))"
    }
}
