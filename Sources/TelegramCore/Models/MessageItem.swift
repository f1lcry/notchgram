import Foundation
@preconcurrency import TDLibKit

/// A stable identity for a message row.
///
/// **Not the message id.** A message sent from here starts life with a
/// temporary id, and `updateMessageSendSucceeded` replaces the whole object with
/// a different one — TDLib's own wording is that "almost any field can be
/// different". Keying rows on the id therefore makes SwiftUI tear the row down
/// and build a new one at the moment of confirmation, which reads as a flicker
/// in the middle of a conversation.
///
/// A locally-originated row keeps its `sendingId` key for life; server messages
/// key on their (already final) id.
public enum MessageKey: Hashable, Sendable {
    /// `MessageSendOptions.sendingId` — an `Int`, not `Int64`, not `TdInt64`.
    case local(Int)
    case server(Int64)
}

public enum MessageSendStatus: Equatable, Hashable, Sendable {
    /// Confirmed by the server.
    case sent
    /// Optimistically shown, waiting for the server.
    case pending
    /// Rejected. Carries the reason so the retry affordance can explain itself.
    case failed(String)
}

/// One reaction chip under a bubble: the emoji, how many, and whether one of
/// them is ours. Custom-emoji and paid reactions are not renderable without a
/// sticker pipeline, so they are dropped at the boundary rather than drawn as
/// placeholders.
public struct MessageReactionChip: Equatable, Hashable, Sendable {
    public let emoji: String
    public let count: Int
    public let isChosen: Bool

    public init(emoji: String, count: Int, isChosen: Bool) {
        self.emoji = emoji
        self.count = count
        self.isChosen = isChosen
    }

    public static func chips(from info: MessageInteractionInfo?) -> [MessageReactionChip] {
        guard let reactions = info?.reactions?.reactions else { return [] }
        return reactions.compactMap { reaction in
            guard case .reactionTypeEmoji(let value) = reaction.type else { return nil }
            return MessageReactionChip(
                emoji: value.emoji, count: reaction.totalCount, isChosen: reaction.isChosen)
        }
    }
}

/// A link inside message text. `offset`/`length` are UTF-16 code units, which
/// is how TDLib counts — an emoji before the link shifts it by two, not one.
public struct TextLink: Equatable, Hashable, Sendable {
    public let offset: Int
    public let length: Int
    public let url: String

    public init(offset: Int, length: Int, url: String) {
        self.offset = offset
        self.length = length
        self.url = url
    }
}

/// One rendered message.
///
/// `content` stays a `TDLibKit.MessageContent` on purpose: it has well over a
/// hundred cases and TDLib adds more every release, so re-modelling it would be
/// a permanent maintenance tax for no gain. It is a value type all the way down
/// (see `TDLibKit+Sendable.swift`).
public struct MessageItem: Identifiable, Equatable, Sendable {
    public var id: MessageKey
    /// 0 until the server has assigned one.
    public var messageId: Int64
    public var chatId: Int64
    public var senderUserId: Int64
    public var senderName: String
    public var isOutgoing: Bool
    public var date: Int
    public var editDate: Int
    public var content: MessageContent
    public var status: MessageSendStatus
    /// The other side has read it. Meaningless for incoming messages.
    public var isReadByPeer: Bool
    public var replyToMessageId: Int64?
    /// True for the service-message content cases, which render as a centred
    /// line rather than a bubble.
    public var isService: Bool
    /// Emoji reactions, from `interactionInfo`; live via
    /// `updateMessageInteractionInfo`.
    public var reactions: [MessageReactionChip]
    /// Non-zero groups consecutive messages into one album post (Telegram's
    /// `media_album_id`); the view renders the run as a single mosaic.
    public var mediaAlbumId: Int64

    public var isEdited: Bool { editDate > 0 }

    /// Server ids are `server_id << 20`, so a real server message has its low
    /// 20 bits clear. A temporary one does not — this is the cheap test for
    /// "has the server seen this".
    public var hasServerId: Bool { messageId != 0 && messageId % 1_048_576 == 0 }

    public var text: String? {
        switch content {
        case .messageText(let value): value.text.text
        default: nil
        }
    }

    /// Links inside a text message: bare URLs (`textEntityTypeUrl`, the URL is
    /// the covered text itself) and named links (`textEntityTypeTextUrl`).
    /// Offsets stay in TDLib's UTF-16 units — the view converts them.
    public var textLinks: [TextLink] {
        guard case .messageText(let value) = content else { return [] }
        let text = value.text.text
        let utf16 = Array(text.utf16)
        return value.text.entities.compactMap { entity in
            guard entity.offset >= 0, entity.length > 0,
                  entity.offset + entity.length <= utf16.count
            else { return nil }
            switch entity.type {
            case .textEntityTypeUrl:
                let covered = String(
                    decoding: utf16[entity.offset..<(entity.offset + entity.length)],
                    as: UTF16.self)
                // Telegram links bare domains too; give them a scheme.
                let url = covered.contains("://") ? covered : "https://\(covered)"
                return TextLink(offset: entity.offset, length: entity.length, url: url)
            case .textEntityTypeTextUrl(let named):
                return TextLink(offset: entity.offset, length: entity.length, url: named.url)
            default:
                return nil
            }
        }
    }

    public init(
        id: MessageKey,
        messageId: Int64,
        chatId: Int64,
        senderUserId: Int64,
        senderName: String,
        isOutgoing: Bool,
        date: Int,
        editDate: Int = 0,
        content: MessageContent,
        status: MessageSendStatus = .sent,
        isReadByPeer: Bool = false,
        replyToMessageId: Int64? = nil,
        isService: Bool = false,
        reactions: [MessageReactionChip] = [],
        mediaAlbumId: Int64 = 0
    ) {
        self.id = id
        self.messageId = messageId
        self.chatId = chatId
        self.senderUserId = senderUserId
        self.senderName = senderName
        self.isOutgoing = isOutgoing
        self.date = date
        self.editDate = editDate
        self.content = content
        self.status = status
        self.isReadByPeer = isReadByPeer
        self.replyToMessageId = replyToMessageId
        self.isService = isService
        self.reactions = reactions
        self.mediaAlbumId = mediaAlbumId
    }

    public init(_ message: Message, senderName: String = "", isReadByPeer: Bool = false) {
        let senderUserId: Int64
        if case .messageSenderUser(let sender) = message.senderId {
            senderUserId = sender.userId
        } else {
            senderUserId = 0
        }

        var status = MessageSendStatus.sent
        switch message.sendingState {
        case .messageSendingStatePending: status = .pending
        case .messageSendingStateFailed(let failure): status = .failed(failure.error.message)
        case nil: status = .sent
        }

        var replyTo: Int64?
        if case .messageReplyToMessage(let reply) = message.replyTo {
            replyTo = reply.messageId
        }

        self.init(
            id: .server(message.id),
            messageId: message.id,
            chatId: message.chatId,
            senderUserId: senderUserId,
            senderName: senderName,
            isOutgoing: message.isOutgoing,
            date: message.date,
            editDate: message.editDate,
            content: message.content,
            status: status,
            isReadByPeer: isReadByPeer,
            replyToMessageId: replyTo,
            isService: MessageItem.isServiceContent(message.content),
            reactions: MessageReactionChip.chips(from: message.interactionInfo),
            mediaAlbumId: message.mediaAlbumId.rawValue)
    }

    /// Service messages ("X joined", "photo changed") render as a centred line,
    /// not as somebody's bubble.
    static func isServiceContent(_ content: MessageContent) -> Bool {
        switch content {
        case .messageText, .messagePhoto, .messageVideo, .messageAnimation, .messageSticker,
             .messageVoiceNote, .messageVideoNote, .messageAudio, .messageDocument,
             .messageLocation, .messageVenue, .messageContact, .messagePoll, .messageDice,
             .messageAnimatedEmoji, .messageUnsupported:
            false
        default:
            true
        }
    }
}
