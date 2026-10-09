#if DEBUG
import Foundation
@preconcurrency import TDLibKit

/// The fictional world demo mode shows (`NOTCHGRAM_DEMO=1`, Debug only).
///
/// Every person, group and message here is invented; the names are generic
/// English names, links point at `example.org`, and every picture is drawn by
/// `DemoArtwork` at launch. Nothing is fetched and nothing is read from a real
/// account.
///
/// The content is delivered as ordinary TDLib `Update` values through
/// `TelegramSession.injectUpdate`, and a chat's history arrives through
/// `MessageRepo`'s offline hook when the chat is opened — so the chat list,
/// folders, conversation and media views on screen are the real views running
/// their real code paths, only over fixture data.
@MainActor
enum DemoContent {

    static let account = TDAccount(id: "demo", label: "Demo")

    // MARK: - Cast

    private struct Person {
        let id: Int64
        let first: String
        let last: String
        var avatar: DemoArtwork.AvatarStyle?
        var isBot = false
    }

    private static let me = Person(id: 100, first: "Alex", last: "Rivera", avatar: nil)

    private static let maya = Person(
        id: 201, first: "Maya", last: "Chen",
        avatar: .scene(.duskRidge, seed: 11))
    private static let leo = Person(id: 202, first: "Leo", last: "Hartmann", avatar: nil)
    private static let priya = Person(
        id: 203, first: "Priya", last: "Nair",
        avatar: .bubbles(0xF2C14E, 0xF78154, 0x4D9078, seed: 3))
    private static let sam = Person(id: 204, first: "Sam", last: "Okafor", avatar: nil)
    private static let elena = Person(
        id: 205, first: "Elena", last: "Rossi",
        avatar: .scene(.seaSunrise, seed: 5))
    private static let jonas = Person(id: 206, first: "Jonas", last: "Berg", avatar: nil)
    private static let noor = Person(
        id: 207, first: "Noor", last: "Haddad",
        avatar: .bubbles(0x2E4057, 0x64D2FF, 0xB388EB, seed: 8))
    private static let tom = Person(
        id: 208, first: "Tom", last: "Becker",
        avatar: .scene(.forestFog, seed: 21))
    private static let bot = Person(
        id: 209, first: "Deploy Bot", last: "",
        avatar: .glyph("shippingbox.fill", top: 0x64D2FF, bottom: 0x2B6CB0), isBot: true)

    private static let people = [me, maya, leo, priya, sam, elena, jonas, noor, tom, bot]

    /// Channel posts carry no person: sender id 0 resolves to no name, so the
    /// list shows the post without a "Name:" prefix, as a channel should.
    private static let channelPost = Person(id: 0, first: "", last: "", avatar: nil)

    // MARK: - Chats

    private static let designCrit = UpdateFixtures.supergroupChatId(11)
    private static let trailCrew = UpdateFixtures.supergroupChatId(12)
    private static let bookClub = UpdateFixtures.supergroupChatId(13)
    private static let radio = UpdateFixtures.supergroupChatId(31)
    private static let flat = UpdateFixtures.basicGroupChatId(21)

    /// Folder ids, as `updateChatFolders` delivers them.
    private enum Folder: Int, CaseIterable {
        case personal = 1, work = 2, hobbies = 3

        var title: String {
            switch self {
            case .personal: "Friends"
            case .work: "Work"
            case .hobbies: "Fun"
            }
        }

        var icon: String {
            switch self {
            case .personal: "Private"
            case .work: "Work"
            case .hobbies: "Favorite"
            }
        }
    }

    private struct ChatSpec {
        let id: Int64
        let title: String
        var type: ChatType? = nil
        var avatar: DemoArtwork.AvatarStyle? = nil
        var pinned = false
        var muted = false
        var unread = 0
        var folders: Set<Folder> = []
        var draft: String? = nil
    }

    // MARK: - File ids

    /// Generated files, keyed by TDLib-style file id. Avatars 7000+, photos
    /// 8000+, the rest 8100+.
    private static var files: [Int: (path: String, size: Int64)] = [:]
    private static let stickerFileId = 8101
    private static let voiceFileId = 8102
    private static let photoFileIds: [DemoArtwork.Scene: Int] = [
        .duskRidge: 8001, .alpineLake: 8002, .forestFog: 8003, .starryNight: 8004,
        .seaSunrise: 8005,
    ]
    private static let photoSize = (width: 1280, height: 854)

    // MARK: - Install

    /// Generates the artwork, then feeds the whole world in through the
    /// session's sink path. Call once, right after `attachRepos`.
    static func install(session: TelegramSession, messageRepo: MessageRepo) {
        let now = Int(Date().timeIntervalSince1970)
        generateFiles()

        var updates: [Update] = []
        for (id, file) in files.sorted(by: { $0.key < $1.key }) {
            updates.append(UpdateFixtures.fileUpdated(UpdateFixtures.file(
                id: id, size: file.size, downloadedCompleted: true, path: file.path)))
        }
        for person in people {
            updates.append(.updateUser(UpdateUser(user: user(person))))
        }
        // Folders before any chat: a folder's order index exists only once the
        // folder does, and chats carry their folder positions with them.
        updates.append(.updateChatFolders(UpdateChatFolders(
            areTagsEnabled: false,
            chatFolders: Folder.allCases.map { folder in
                ChatFolderInfo(
                    colorId: -1,
                    hasMyInviteLinks: false,
                    icon: ChatFolderIcon(name: folder.icon),
                    id: folder.rawValue,
                    isShareable: false,
                    name: ChatFolderName(
                        animateCustomEmoji: false,
                        text: FormattedText(entities: [], text: folder.title)))
            },
            mainChatListPosition: 0)))

        let histories = makeHistories(now: now)
        var order: Int64 = 1_000_000
        for spec in chatSpecs() {
            order -= 1_000
            let history = histories[spec.id] ?? []
            let lastMessage = history.last
            var positions = [UpdateFixtures.position(order: order, isPinned: spec.pinned)]
            for folder in spec.folders.sorted(by: { $0.rawValue < $1.rawValue }) {
                positions.append(UpdateFixtures.position(
                    order: order,
                    isPinned: false,
                    list: .chatListFolder(ChatListFolder(chatFolderId: folder.rawValue))))
            }
            let lastIncoming = history.last(where: { !$0.isOutgoing })?.id ?? 0
            let firstUnread = history.filter { !$0.isOutgoing }.suffix(spec.unread).first?.id
            let lastReadInbox = firstUnread.map { id in
                history.last(where: { $0.id < id })?.id ?? 0
            } ?? lastIncoming
            updates.append(UpdateFixtures.newChat(UpdateFixtures.chat(
                id: spec.id,
                title: spec.title,
                positions: positions,
                lastMessage: lastMessage,
                unreadCount: spec.unread,
                isMuted: spec.muted,
                type: spec.type,
                photo: spec.avatar.flatMap { _ in chatPhoto(for: spec.id) },
                lastReadInboxMessageId: lastReadInbox,
                lastReadOutboxMessageId: readOutbox[spec.id] ?? (lastMessage?.id ?? 0),
                draft: spec.draft.map(UpdateFixtures.draft))))
            unreadByChat[spec.id] = (spec.unread, spec.muted, spec.folders)
        }
        updates.append(contentsOf: unreadCountUpdates())

        session.enterOfflineDemo(me: user(me))
        for update in updates { session.injectUpdate(update) }

        // History on open: the chat's messages plus its read-outbox marker,
        // which is what turns a sent tick into a read one.
        messageRepo.offlineHistory = { chatId in
            var updates = (histories[chatId] ?? []).map(UpdateFixtures.newMessage)
            if let outbox = readOutbox[chatId] ?? histories[chatId]?.last?.id {
                updates.append(.updateChatReadOutbox(UpdateChatReadOutbox(
                    chatId: chatId, lastReadOutboxMessageId: outbox)))
            }
            return updates
        }
        // Read receipts: what TDLib would answer to `viewMessages`. Seeing the
        // newest incoming message clears the chat's badge (and the folder
        // tabs' counts), exactly as on a live account.
        messageRepo.viewMessagesSender = { [weak session] chatId, messageIds in
            guard let session, let newest = messageIds.max(),
                  let entry = unreadByChat[chatId], entry.count > 0 else { return }
            let lastIncoming = histories[chatId]?.last(where: { !$0.isOutgoing })?.id ?? 0
            guard newest >= lastIncoming else { return }
            unreadByChat[chatId] = (0, entry.muted, entry.folders)
            session.injectUpdate(.updateChatReadInbox(UpdateChatReadInbox(
                chatId: chatId, lastReadInboxMessageId: newest, unreadCount: 0)))
            for update in unreadCountUpdates() { session.injectUpdate(update) }
        }
    }

    // MARK: - The list

    private static func chatSpecs() -> [ChatSpec] {
        [
            ChatSpec(id: maya.id, title: "Maya Chen", avatar: maya.avatar, pinned: true,
                     folders: [.personal]),
            ChatSpec(id: designCrit, title: "Design Crit",
                     type: supergroup(designCrit),
                     avatar: .glyph("paintpalette.fill", top: 0xB388EB, bottom: 0x5B3E96),
                     pinned: true, unread: 14, folders: [.work]),
            ChatSpec(id: me.id, title: "", pinned: true),
            ChatSpec(id: trailCrew, title: "Trail Crew",
                     type: supergroup(trailCrew),
                     avatar: .scene(.alpineLake, seed: 2), folders: [.hobbies]),
            ChatSpec(id: leo.id, title: "Leo Hartmann", folders: [.work]),
            ChatSpec(id: radio, title: "Night Shift FM",
                     type: .chatTypeSupergroup(ChatTypeSupergroup(isChannel: true, supergroupId: 31)),
                     avatar: .glyph("waveform", top: 0xF2749A, bottom: 0x4A1942),
                     muted: true, unread: 128, folders: [.hobbies]),
            ChatSpec(id: bot.id, title: "Deploy Bot", avatar: bot.avatar, unread: 1,
                     folders: [.work]),
            ChatSpec(id: priya.id, title: "Priya Nair", avatar: priya.avatar,
                     folders: [.personal], draft: "Let me check the venue and"),
            ChatSpec(id: flat, title: "Flat 4B",
                     type: .chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: 21)),
                     avatar: .glyph("house.fill", top: 0x76C84D, bottom: 0x2F6B3A),
                     unread: 3, folders: [.personal]),
            ChatSpec(id: elena.id, title: "Elena Rossi", avatar: elena.avatar, unread: 1,
                     folders: [.personal]),
            ChatSpec(id: bookClub, title: "Book Club",
                     type: supergroup(bookClub),
                     avatar: .glyph("book.fill", top: 0xF2C14E, bottom: 0xB0601E),
                     muted: true, unread: 9, folders: [.hobbies]),
            ChatSpec(id: noor.id, title: "Noor Haddad", avatar: noor.avatar,
                     folders: [.personal]),
            ChatSpec(id: tom.id, title: "Tom Becker", avatar: tom.avatar,
                     folders: [.personal]),
            ChatSpec(id: sam.id, title: "Sam Okafor", folders: [.personal]),
        ]
    }

    /// Explicit read-outbox markers. Chats not listed have read everything we
    /// sent; Tom's marker sits below our last message, so its tick stays single.
    private static var readOutbox: [Int64: Int64] = [
        maya.id: UpdateFixtures.serverMessageId(110),
        tom.id: UpdateFixtures.serverMessageId(1),
    ]

    private static var unreadByChat: [Int64: (count: Int, muted: Bool, folders: Set<Folder>)] = [:]

    /// Telegram's tab badges count unmuted chats with unread messages, per list.
    private static func unreadCountUpdates() -> [Update] {
        func update(_ list: ChatList, _ entries: [(count: Int, muted: Bool, folders: Set<Folder>)]) -> Update {
            let unread = entries.filter { $0.count > 0 }
            return .updateUnreadChatCount(UpdateUnreadChatCount(
                chatList: list,
                markedAsUnreadCount: 0,
                markedAsUnreadUnmutedCount: 0,
                totalCount: entries.count,
                unreadCount: unread.count,
                unreadUnmutedCount: unread.filter { !$0.muted }.count))
        }
        let all = Array(unreadByChat.values)
        var updates = [update(.chatListMain, all)]
        for folder in Folder.allCases {
            updates.append(update(
                .chatListFolder(ChatListFolder(chatFolderId: folder.rawValue)),
                all.filter { $0.folders.contains(folder) }))
        }
        return updates
    }

    // MARK: - Histories

    private static func makeHistories(now: Int) -> [Int64: [Message]] {
        // The "today" story runs until 10:00. Launched earlier than that, the
        // whole script moves back a day, so no message is ever in the future
        // and the timestamps stay distinct whatever time `make media` runs.
        let midnight = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let today = now - midnight < 10 * 3600 + 1800 ? midnight - 86_400 : midnight
        let todayAt = { (hour: Int, minute: Int) -> Int in
            today + hour * 3600 + minute * 60
        }
        let yesterdayAt = { (hour: Int, minute: Int) -> Int in
            today - 86_400 + hour * 3600 + minute * 60
        }
        var result: [Int64: [Message]] = [:]

        func message(
            _ n: Int64, in chat: Int64, from sender: Person, _ content: MessageContent,
            at date: Int, album: Int64 = 0, replyTo: Int64? = nil,
            reactions: [(String, Int, Bool)] = []
        ) -> Message {
            UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(n),
                chatId: chat,
                senderUserId: sender.id,
                content: content,
                isOutgoing: sender.id == me.id,
                date: date,
                mediaAlbumId: album,
                replyToMessageId: replyTo.map(UpdateFixtures.serverMessageId),
                interactionInfo: reactions.isEmpty ? nil : interaction(reactions))
        }
        let text: (String) -> MessageContent = UpdateFixtures.text

        // Maya — the showcase conversation: replies, a link, a voice note, a
        // photo with a reaction, a sticker, read and unread ticks.
        let link = "https://trails.example.org/lake-loop"
        let linkText = "Found the route: \(link)"
        result[maya.id] = [
            message(101, in: maya.id, from: maya, text("Back from the ridge trail!"), at: yesterdayAt(18, 2)),
            message(102, in: maya.id, from: maya, text("The view from the top was ridiculous"), at: yesterdayAt(18, 3)),
            message(103, in: maya.id, from: me, text("Photos or it didn't happen 😄"), at: yesterdayAt(18, 10)),
            message(104, in: maya.id, from: maya,
                    photo(.duskRidge, caption: "Golden hour at the summit"),
                    at: yesterdayAt(18, 14), reactions: [("🔥", 1, true)]),
            message(105, in: maya.id, from: me, text("Okay, that's unreal. Phone or camera?"),
                    at: yesterdayAt(18, 16), replyTo: 104),
            message(106, in: maya.id, from: maya, text("Just my phone, the light did all the work"),
                    at: yesterdayAt(18, 21)),
            message(107, in: maya.id, from: maya, voice(duration: 23), at: todayAt(9, 12)),
            message(108, in: maya.id, from: me, text("Ha, yes. Lake loop next weekend? I'll bring coffee ☕"),
                    at: todayAt(9, 20), replyTo: 107),
            message(109, in: maya.id, from: maya,
                    UpdateFixtures.text(
                        linkText,
                        entities: UpdateFixtures.urlEntity(link, in: linkText).map { [$0] } ?? []),
                    at: todayAt(9, 24), reactions: [("👍", 1, false)]),
            message(110, in: maya.id, from: me, sticker("🏕"), at: todayAt(9, 32)),
            message(111, in: maya.id, from: maya, text("Perfect, see you at 8 ☀️"), at: todayAt(9, 41)),
        ]

        // Trail Crew — a group: sender names and avatars, an album mosaic.
        let album: Int64 = 9_001
        result[trailCrew] = [
            message(201, in: trailCrew, from: tom, text("Who's in for Saturday?"), at: yesterdayAt(20, 5)),
            message(202, in: trailCrew, from: jonas, text("Me! Bringing the big thermos"), at: yesterdayAt(20, 9)),
            message(203, in: trailCrew, from: me, text("Count me in"), at: yesterdayAt(20, 15)),
            message(204, in: trailCrew, from: maya, photo(.duskRidge), at: todayAt(8, 2), album: album),
            message(205, in: trailCrew, from: maya, photo(.alpineLake), at: todayAt(8, 2), album: album),
            message(206, in: trailCrew, from: maya, photo(.forestFog), at: todayAt(8, 2), album: album),
            message(207, in: trailCrew, from: maya, photo(.starryNight), at: todayAt(8, 2), album: album),
            message(208, in: trailCrew, from: maya,
                    text("Some shots from last weekend's scouting trip"),
                    at: todayAt(8, 3), reactions: [("❤️", 3, true)]),
            message(209, in: trailCrew, from: tom, text("That lake! We're going there"), at: todayAt(8, 11)),
        ]

        result[designCrit] = [
            message(301, in: designCrit, from: priya, text("Morning! New onboarding flow is up for review"), at: todayAt(8, 40)),
            message(302, in: designCrit, from: noor, text("The second step feels long, can we split it?"), at: todayAt(8, 52)),
            message(303, in: designCrit, from: priya, text("Good call, I'll try a two-step version"), at: todayAt(9, 5)),
            message(304, in: designCrit, from: leo, text("Pushed the new spacing, take a look"), at: todayAt(9, 58)),
        ]
        result[me.id] = [
            message(401, in: me.id, from: me, text("Idea: tiny timers that live in the notch"), at: yesterdayAt(23, 12)),
        ]
        result[leo.id] = [
            message(501, in: leo.id, from: leo, text("Can you send me the slides?"), at: todayAt(8, 30)),
            message(502, in: leo.id, from: me, text("Sent! Slide 12 has the new numbers"), at: todayAt(8, 44)),
        ]
        result[radio] = [
            message(601, in: radio, from: channelPost, text("New mix: rain on a tin roof, two hours"), at: todayAt(7, 0)),
        ]
        result[bot.id] = [
            message(701, in: bot.id, from: bot, text("✅ Build 0.4.2 passed: 312 tests, 0 failures"), at: todayAt(7, 48)),
        ]
        result[priya.id] = [
            message(801, in: priya.id, from: priya, text("Are we still on for Friday dinner?"), at: yesterdayAt(17, 30)),
        ]
        result[flat] = [
            message(901, in: flat, from: jonas, text("Who has the spare key?"), at: yesterdayAt(19, 2)),
            message(902, in: flat, from: me, text("It's in the blue bowl"), at: yesterdayAt(19, 10)),
            message(903, in: flat, from: sam, text("Heating is fixed 🎉"), at: yesterdayAt(21, 40)),
            message(904, in: flat, from: jonas, text("Legend"), at: yesterdayAt(21, 42)),
            message(905, in: flat, from: sam, text("I'll pick up groceries on the way"), at: yesterdayAt(22, 5)),
        ]
        result[elena.id] = [
            message(1001, in: elena.id, from: elena, photo(.seaSunrise, caption: "Sunrise from the balcony"),
                    at: yesterdayAt(6, 50)),
        ]
        result[bookClub] = [
            message(1101, in: bookClub, from: jonas, text("Chapter 7 tonight?"), at: yesterdayAt(16, 20)),
        ]
        result[noor.id] = [
            message(1201, in: noor.id, from: noor, voice(duration: 41), at: yesterdayAt(13, 5)),
        ]
        result[tom.id] = [
            message(1301, in: tom.id, from: me, text("On my way 🚲"), at: yesterdayAt(12, 25)),
        ]
        result[sam.id] = [
            message(1401, in: sam.id, from: sam, text("Thanks for dinner yesterday!"), at: yesterdayAt(10, 3)),
            message(1402, in: sam.id, from: me, text("Anytime 🙂"), at: yesterdayAt(10, 9)),
        ]
        return result
    }

    // MARK: - Builders

    private static func user(_ person: Person) -> User {
        UpdateFixtures.user(
            id: person.id,
            firstName: person.first,
            lastName: person.last,
            profilePhoto: person.avatar.map { _ in
                ProfilePhoto(
                    big: avatarFile(for: person.id),
                    hasAnimation: false,
                    id: TdInt64(person.id),
                    isPersonal: false,
                    minithumbnail: nil,
                    small: avatarFile(for: person.id))
            },
            type: person.isBot ? botType : .userTypeRegular,
            usernames: person.id == me.id
                ? Usernames(
                    activeUsernames: ["alexrivera"], collectibleUsernames: [],
                    disabledUsernames: [], editableUsername: "alexrivera")
                : nil)
    }

    private static let botType = UserType.userTypeBot(UserTypeBot(
        activeUserCount: 0, allowsUsersToCreateTopics: false, canBeAddedToAttachmentMenu: false,
        canBeEdited: false, canConnectToBusiness: false, canJoinGroups: false,
        canManageBots: false, canReadAllGroupMessages: false, hasMainWebApp: false,
        hasTopics: false, inlineQueryPlaceholder: "", isGuard: false, isInline: false,
        needLocation: false, supportsGuestQueries: false))

    private static func supergroup(_ chatId: Int64) -> ChatType {
        .chatTypeSupergroup(ChatTypeSupergroup(
            isChannel: false, supergroupId: -chatId - 1_000_000_000_000))
    }

    /// Avatar file ids: 7000 + a stable index derived from the chat id.
    private static func avatarFileId(for id: Int64) -> Int {
        7000 + Int(UInt64(bitPattern: id) % 997)
    }

    private static func avatarFile(for id: Int64) -> File {
        let fileId = avatarFileId(for: id)
        let entry = files[fileId]
        return UpdateFixtures.file(
            id: fileId, size: entry?.size ?? 0,
            downloadedCompleted: entry != nil, path: entry?.path ?? "")
    }

    private static func chatPhoto(for id: Int64) -> ChatPhotoInfo {
        ChatPhotoInfo(
            big: avatarFile(for: id), hasAnimation: false, isPersonal: false,
            minithumbnail: nil, small: avatarFile(for: id))
    }

    private static func photo(_ scene: DemoArtwork.Scene, caption: String = "") -> MessageContent {
        let fileId = photoFileIds[scene] ?? 8000
        let entry = files[fileId]
        let size = PhotoSize(
            height: photoSize.height,
            photo: UpdateFixtures.file(
                id: fileId, size: entry?.size ?? 0,
                downloadedCompleted: entry != nil, path: entry?.path ?? ""),
            progressiveSizes: [],
            type: "y",
            width: photoSize.width)
        return UpdateFixtures.photo(caption: caption, sizes: [size])
    }

    private static func sticker(_ emoji: String) -> MessageContent {
        let entry = files[stickerFileId]
        return .messageSticker(MessageSticker(
            isPremium: false,
            sticker: Sticker(
                emoji: emoji,
                format: .stickerFormatWebp,
                fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
                height: 512,
                id: TdInt64(1),
                setId: TdInt64(0),
                sticker: UpdateFixtures.file(
                    id: stickerFileId, size: entry?.size ?? 0,
                    downloadedCompleted: entry != nil, path: entry?.path ?? ""),
                thumbnail: nil,
                width: 512)))
    }

    private static func voice(duration: Int) -> MessageContent {
        let entry = files[voiceFileId]
        return UpdateFixtures.voiceNote(
            duration: duration,
            fileId: voiceFileId,
            waveform: DemoArtwork.packedWaveform(count: 63, seed: UInt64(duration)),
            voice: UpdateFixtures.file(
                id: voiceFileId, size: entry?.size ?? 0,
                downloadedCompleted: entry != nil, path: entry?.path ?? ""))
    }

    private static func interaction(_ reactions: [(String, Int, Bool)]) -> MessageInteractionInfo {
        MessageInteractionInfo(
            forwardCount: 0,
            reactions: MessageReactions(
                areTags: false,
                canGetAddedReactions: false,
                paidReactors: [],
                reactions: reactions.map { emoji, count, chosen in
                    MessageReaction(
                        isChosen: chosen,
                        recentSenderIds: [],
                        totalCount: count,
                        type: .reactionTypeEmoji(ReactionTypeEmoji(emoji: emoji)),
                        usedSenderId: nil)
                }),
            replyInfo: nil,
            viewCount: 0)
    }

    // MARK: - Files

    /// Draws every picture into a throwaway directory under the temp dir —
    /// never the app's support directory, never an account directory.
    private static func generateFiles() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchGramDemo/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = [:]

        func record(_ id: Int, _ url: URL) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            files[id] = (url.path, Int64(size))
        }

        var avatars: [(Int64, DemoArtwork.AvatarStyle)] = people.compactMap { person in
            person.avatar.map { (person.id, $0) }
        }
        for spec in chatSpecs() where spec.id < 0 {
            if let avatar = spec.avatar { avatars.append((spec.id, avatar)) }
        }
        for (id, style) in avatars {
            let url = directory.appendingPathComponent("avatar-\(avatarFileId(for: id)).png")
            if DemoArtwork.writePNG(DemoArtwork.avatar(style), to: url) {
                record(avatarFileId(for: id), url)
            }
        }
        for (scene, fileId) in photoFileIds {
            let url = directory.appendingPathComponent("photo-\(fileId).png")
            let image = DemoArtwork.landscape(
                scene, width: photoSize.width, height: photoSize.height, seed: UInt64(fileId))
            if DemoArtwork.writePNG(image, to: url) { record(fileId, url) }
        }
        let stickerURL = directory.appendingPathComponent("sticker.png")
        if DemoArtwork.writePNG(DemoArtwork.sticker("🏕"), to: stickerURL) {
            record(stickerFileId, stickerURL)
        }
        let voiceURL = directory.appendingPathComponent("voice.wav")
        if DemoArtwork.writeVoiceClip(to: voiceURL, seconds: 23) {
            record(voiceFileId, voiceURL)
        }
    }
}
#endif
