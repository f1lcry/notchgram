// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import TDLibKit

/// Named fixture scenarios for DebugBridge's `injectFixture`.
///
/// Telegram's test DC cannot log in (D29), so this is the only way the client UI
/// gets data before the founder's real account is signed in. It is also how the
/// awkward cases get looked at on purpose rather than by luck: a muted channel
/// with 4 000 unread, a chat whose last message is an outgoing photo that has
/// been read, a draft in progress, a group where the preview needs a sender
/// prefix.
enum DebugFixtureScenarios {
    static let names = ["chatList", "chatListBusy", "conversation", "media", "clear"]

    static func updates(named name: String) throws -> [Update] {
        switch name {
        case "chatList": chatList()
        case "chatListBusy": chatList(extra: 24)
        case "conversation": conversation()
        case "media": media()
        case "clear": []
        default:
            throw DebugRouterError.missingArgument(
                "fixture must be one of: \(names.joined(separator: ", "))")
        }
    }

    /// A believable list: pinned first, a channel, a group needing a sender
    /// prefix, a bot, a draft, muted-with-unread, and Saved Messages.
    private static func chatList(extra: Int = 0) -> [Update] {
        var updates: [Update] = []
        var order: Int64 = 10_000

        func add(
            id: Int64,
            title: String,
            preview: MessageContent,
            senderUserId: Int64,
            outgoing: Bool = false,
            unread: Int = 0,
            pinned: Bool = false,
            muted: Bool = false,
            minutesAgo: Int = 5
        ) {
            order -= 1
            let message = UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(order),
                chatId: id,
                senderUserId: senderUserId,
                content: preview,
                isOutgoing: outgoing,
                date: Int(Date().timeIntervalSince1970) - minutesAgo * 60)
            let chat = UpdateFixtures.chat(
                id: id,
                title: title,
                positions: [UpdateFixtures.position(order: order, isPinned: pinned)],
                lastMessage: message,
                unreadCount: unread,
                isMuted: muted)
            updates.append(UpdateFixtures.newChat(chat))
        }

        updates.append(.updateUser(UpdateAuthorizationStateFreeUser(id: 501, first: "Anna", last: "Petrova")))
        updates.append(.updateUser(UpdateAuthorizationStateFreeUser(id: 502, first: "Dmitry", last: "Sokolov")))
        updates.append(.updateUser(UpdateAuthorizationStateFreeUser(id: 503, first: "Marina", last: "Ivanova")))

        add(id: 501, title: "Anna Petrova",
            preview: UpdateFixtures.text("Sounds good — see you at seven"),
            senderUserId: 501, unread: 2, pinned: true, minutesAgo: 3)
        add(id: UpdateFixtures.supergroupChatId(11), title: "Design review",
            preview: UpdateFixtures.text("pushed the new spacing, take a look"),
            senderUserId: 502, unread: 14, pinned: true, minutesAgo: 12)
        add(id: 502, title: "Dmitry Sokolov",
            preview: UpdateFixtures.text("Thanks!"),
            senderUserId: 0, outgoing: true, minutesAgo: 40)
        add(id: UpdateFixtures.supergroupChatId(12), title: "Swift Weekly",
            preview: UpdateFixtures.text("Issue 412 is out"),
            senderUserId: 503, unread: 4213, muted: true, minutesAgo: 90)
        add(id: 503, title: "Marina Ivanova",
            preview: UpdateFixtures.text("could you send the file?"),
            senderUserId: 503, unread: 1, minutesAgo: 180)
        add(id: UpdateFixtures.basicGroupChatId(21), title: "Flat 42",
            preview: UpdateFixtures.text("I'll pick up the keys"),
            senderUserId: 501, minutesAgo: 400)

        for index in 0..<extra {
            add(id: 900 + Int64(index),
                title: "Contact \(index + 1)",
                preview: UpdateFixtures.text("Message \(index + 1)"),
                senderUserId: 900 + Int64(index),
                unread: index % 4 == 0 ? index + 1 : 0,
                muted: index % 5 == 0,
                minutesAgo: 600 + index * 37)
        }
        return updates
    }

    /// The chat the `conversation` fixture fills. Matches a row in `chatList`
    /// so the two scenarios compose.
    static let conversationChatId: Int64 = 501

    /// A believable exchange: a day boundary, a run of messages from one sender
    /// (so only the first carries a name), an outgoing message already read, one
    /// still sending, and one that failed — the states a bubble has to draw.
    private static func conversation() -> [Update] {
        var updates: [Update] = [
            .updateUser(UpdateUser(user: UpdateFixtures.user(
                id: 501, firstName: "Anna", lastName: "Petrova"))),
        ]
        let chatId = conversationChatId
        let now = Int(Date().timeIntervalSince1970)
        let yesterday = now - 26 * 3600

        func incoming(_ id: Int64, _ text: String, at date: Int) {
            updates.append(UpdateFixtures.newMessage(UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(id),
                chatId: chatId,
                senderUserId: 501,
                content: UpdateFixtures.text(text),
                isOutgoing: false,
                date: date)))
        }
        func outgoing(_ id: Int64, _ text: String, at date: Int, state: MessageSendingState? = nil) {
            updates.append(UpdateFixtures.newMessage(UpdateFixtures.message(
                id: state == nil
                    ? UpdateFixtures.serverMessageId(id)
                    : UpdateFixtures.temporaryMessageId(id),
                chatId: chatId,
                senderUserId: 0,
                content: UpdateFixtures.text(text),
                isOutgoing: true,
                date: date,
                sendingState: state)))
        }

        incoming(101, "Are we still on for tomorrow?", at: yesterday)
        outgoing(102, "Yes — 19:00 works", at: yesterday + 120)
        incoming(103, "Perfect.", at: now - 3600)
        incoming(104, "I'll bring the drafts we talked about", at: now - 3595)
        incoming(105, "and the printed spreads", at: now - 3590)
        outgoing(106, "Sounds good, see you at seven", at: now - 1800)
        outgoing(107, "one more thing —", at: now - 60,
                 state: .messageSendingStatePending(MessageSendingStatePending(sendingId: 991)))
        outgoing(108, "this one failed to send", at: now - 30,
                 state: .messageSendingStateFailed(MessageSendingStateFailed(
                     canRetry: true,
                     error: TDLibKit.Error(code: 400, message: "NETWORK_UNAVAILABLE"),
                     needAnotherReplyQuote: false,
                     needAnotherSender: false,
                     needDropReply: false,
                     requiredPaidMessageStarCount: 0,
                     retryAfter: 0)))

        // The outbox marker is what turns a tick from grey to blue; without it
        // every outgoing message looks unread forever.
        updates.append(.updateChatReadOutbox(UpdateChatReadOutbox(
            chatId: chatId, lastReadOutboxMessageId: UpdateFixtures.serverMessageId(102))))
        return updates
    }

    /// One of each media kind, so every renderer gets looked at on purpose.
    ///
    /// Files are made real on disk and announced with `updateFile`, because the
    /// renderers deliberately refuse to draw anything that is not
    /// `isDownloadingCompleted` — TDLib warns the bytes may be garbage before
    /// that, and a fixture that bypassed the check would hide the bug it is
    /// meant to protect against.
    private static func media() -> [Update] {
        let chatId = conversationChatId
        let now = Int(Date().timeIntervalSince1970)
        var updates: [Update] = []
        var id: Int64 = 200

        func post(_ content: MessageContent, outgoing: Bool = false) {
            id += 1
            updates.append(UpdateFixtures.newMessage(UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(id),
                chatId: chatId,
                senderUserId: outgoing ? 0 : 501,
                content: content,
                isOutgoing: outgoing,
                date: now - Int(260 - id) * 30)))
        }

        // Photo — a real file on disk.
        let photoURL = artifactsURL("fixture-photo.png")
        let photoFileId = 9001
        if writePNG(to: photoURL, width: 640, height: 420) {
            updates.append(UpdateFixtures.fileUpdated(UpdateFixtures.file(
                id: photoFileId, size: 96_000, downloadedCompleted: true, path: photoURL.path)))
        }
        post(UpdateFixtures.photo(
            caption: "the spread we discussed",
            sizes: [UpdateFixtures.photoSize(fileId: photoFileId, width: 640, height: 420)]))

        // Sticker — webp is the only format that renders; tgs and webm fall back
        // to a thumbnail or the emoji, which is what these two exercise.
        let stickerURL = artifactsURL("fixture-sticker.png")
        let stickerFileId = 9002
        if writePNG(to: stickerURL, width: 240, height: 240) {
            updates.append(UpdateFixtures.fileUpdated(UpdateFixtures.file(
                id: stickerFileId, size: 20_000, downloadedCompleted: true, path: stickerURL.path)))
        }
        post(.messageSticker(MessageSticker(
            isPremium: false,
            sticker: Sticker(
                emoji: "🎉",
                format: .stickerFormatWebp,
                fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
                height: 240,
                id: TdInt64(1),
                setId: TdInt64(0),
                sticker: UpdateFixtures.file(
                    id: stickerFileId, size: 20_000,
                    downloadedCompleted: true, path: stickerURL.path),
                thumbnail: nil,
                width: 240))))

        post(.messageSticker(MessageSticker(
            isPremium: false,
            sticker: Sticker(
                emoji: "🥳",
                // Unplayable on macOS 26 — no matroska UTI in AVFoundation.
                format: .stickerFormatWebm,
                fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
                height: 240,
                id: TdInt64(2),
                setId: TdInt64(0),
                sticker: UpdateFixtures.file(id: 9003),
                thumbnail: nil,
                width: 240))))

        // Voice — the waveform is unpacked from Telegram's 5-bit packing, so it
        // renders correctly even before the audio is on disk.
        post(UpdateFixtures.voiceNote(duration: 47, fileId: 9004))

        // Video — thumbnail plus duration; the file itself opens externally.
        post(.messageVideo(MessageVideo(
            alternativeVideos: [],
            caption: FormattedText(entities: [], text: "clip from the shoot"),
            cover: nil,
            hasSpoiler: false,
            isSecret: false,
            showCaptionAboveMedia: false,
            startTimestamp: 0,
            storyboards: [],
            video: Video(
                duration: 132,
                fileName: "clip.mp4",
                hasStickers: false,
                height: 720,
                mimeType: "video/mp4",
                minithumbnail: nil,
                supportsStreaming: true,
                thumbnail: nil,
                video: UpdateFixtures.file(id: 9005, size: 8_400_000),
                width: 1280))))

        // Document.
        post(.messageDocument(MessageDocument(
            caption: FormattedText(entities: [], text: ""),
            document: Document(
                document: UpdateFixtures.file(id: 9006, size: 2_400_000),
                fileName: "spacing-spec.pdf",
                mimeType: "application/pdf",
                minithumbnail: nil,
                thumbnail: nil))), outgoing: true)

        return updates
    }

    private static func artifactsURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchGram/fixtures")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(name)
    }

    @discardableResult
    private static func writePNG(to url: URL, width: Int, height: Int) -> Bool {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }

        context.setFillColor(CGColor(red: 0.13, green: 0.20, blue: 0.32, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<9 {
            context.setFillColor(CGColor(
                red: 0.2 + Double(index) * 0.07,
                green: 0.45, blue: 0.75 - Double(index) * 0.05, alpha: 1))
            let side = min(width, height) / 3
            context.fillEllipse(in: CGRect(
                x: (index % 3) * (width / 3) + side / 6,
                y: (index / 3) * (height / 3) + side / 6,
                width: side * 2 / 3, height: side * 2 / 3))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Small helper so the call sites above stay readable.
    private static func UpdateAuthorizationStateFreeUser(
        id: Int64, first: String, last: String
    ) -> UpdateUser {
        UpdateUser(user: UpdateFixtures.user(id: id, firstName: first, lastName: last))
    }
}

#endif
