import XCTest
import TDLibKit
@testable import NotchGram

/// Replays update sequences through the real `ChatRepo`.
///
/// Telegram's test DC cannot log in (D29), so this is where the chat-list rules
/// are actually verified: ordering, previews, mute resolution and read ticks are
/// all pure functions of the inbound stream.
@MainActor
final class ChatRepoTests: XCTestCase {

    private func repo(_ updates: [Update]) -> ChatRepo {
        let repo = ChatRepo()
        for update in updates { repo.apply(update) }
        return repo
    }

    private func chat(
        _ id: Int64,
        _ title: String,
        order: Int64,
        pinned: Bool = false,
        muted: Bool = false,
        unread: Int = 0,
        last: Message? = nil
    ) -> Update {
        UpdateFixtures.newChat(UpdateFixtures.chat(
            id: id,
            title: title,
            positions: [UpdateFixtures.position(order: order, isPinned: pinned)],
            lastMessage: last,
            unreadCount: unread,
            isMuted: muted))
    }

    // MARK: - Ordering and identity

    func testPinnedChatsLeadTheList() {
        let repo = repo([
            chat(1, "Alpha", order: 100),
            chat(2, "Beta", order: 10, pinned: true),
        ])
        XCTAssertEqual(repo.chats.map(\.id), [2, 1])
        XCTAssertTrue(repo.chats[0].isPinned)
    }

    /// A private chat with yourself is Saved Messages, not a contact row — but
    /// only once `getMe` has landed, which is why the id is set separately.
    func testSavedMessagesIsRecognisedOnlyAfterGetMe() {
        let repo = repo([chat(77, "", order: 10)])
        XCTAssertNotEqual(repo.chats.first?.kind, .savedMessages)

        repo.myUserId = 77
        XCTAssertEqual(repo.chats.first?.kind, .savedMessages)
        XCTAssertEqual(repo.chats.first?.title, "Saved Messages")
    }

    /// TDLib sends `updateUser` before it hands the id to the app, so a private
    /// chat with an empty title takes the user's name rather than rendering
    /// blank.
    func testPrivateChatFallsBackToTheUserName() {
        let repo = repo([
            .updateUser(UpdateUser(user: UpdateFixtures.user(
                id: 42, firstName: "Anna", lastName: "Petrova"))),
            chat(42, "", order: 10),
        ])
        XCTAssertEqual(repo.chats.first?.title, "Anna Petrova")
        XCTAssertEqual(repo.chats.first?.initials, "AP")
    }

    // MARK: - Previews

    func testGroupPreviewCarriesASenderPrefix() {
        let groupId = UpdateFixtures.supergroupChatId(5)
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1),
            chatId: groupId,
            senderUserId: 42,
            content: UpdateFixtures.text("pushed the new spacing"))
        let repo = repo([
            .updateUser(UpdateUser(user: UpdateFixtures.user(id: 42, firstName: "Dmitry"))),
            chat(groupId, "Design review", order: 10, last: message),
        ])
        XCTAssertEqual(repo.chats.first?.preview, "Dmitry: pushed the new spacing")
    }

    /// A private chat has exactly two participants, so a sender prefix is noise.
    func testPrivatePreviewHasNoPrefix() {
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1),
            chatId: 42,
            senderUserId: 42,
            content: UpdateFixtures.text("see you at seven"))
        let repo = repo([
            .updateUser(UpdateUser(user: UpdateFixtures.user(id: 42, firstName: "Anna"))),
            chat(42, "Anna", order: 10, last: message),
        ])
        XCTAssertEqual(repo.chats.first?.preview, "see you at seven")
    }

    /// Newlines in a preview would push the row's second line out of view.
    func testPreviewIsFlattenedToOneLine() {
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1), chatId: 42, senderUserId: 42,
            content: UpdateFixtures.text("first\nsecond"))
        let repo = repo([chat(42, "Anna", order: 10, last: message)])
        XCTAssertEqual(repo.chats.first?.preview, "first second")
    }

    func testMediaPreviewsAreDescribed() {
        XCTAssertTrue(MessagePreview.text(for: UpdateFixtures.voiceNote())
            .contains("Voice message"))
        XCTAssertTrue(MessagePreview.text(for: UpdateFixtures.photo()).contains("Photo"))

        // A caption replaces the generic label — that is what Telegram shows.
        XCTAssertTrue(MessagePreview.text(for: UpdateFixtures.photo(caption: "at the beach"))
            .contains("at the beach"))
    }

    // MARK: - Read state

    /// There is no per-message read update; ticks come from comparing the last
    /// message id against the chat's `last_read_outbox_message_id`.
    func testOutgoingTicksFollowTheOutboxReadMarker() {
        let messageId = UpdateFixtures.serverMessageId(9)
        let message = UpdateFixtures.message(
            id: messageId, chatId: 42, senderUserId: 1,
            content: UpdateFixtures.text("Thanks!"), isOutgoing: true)
        let repo = repo([chat(42, "Dmitry", order: 10, last: message)])

        XCTAssertTrue(repo.chats.first?.showsUnreadTicks == true)
        XCTAssertFalse(repo.chats.first?.showsReadTicks == true)

        repo.apply(.updateChatReadOutbox(UpdateChatReadOutbox(
            chatId: 42, lastReadOutboxMessageId: messageId)))
        XCTAssertTrue(repo.chats.first?.showsReadTicks == true)
        XCTAssertFalse(repo.chats.first?.showsUnreadTicks == true)
    }

    func testIncomingMessagesShowNoTicks() {
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(9), chatId: 42, senderUserId: 42,
            content: UpdateFixtures.text("hi"), isOutgoing: false)
        let repo = repo([chat(42, "Anna", order: 10, last: message)])
        XCTAssertFalse(repo.chats.first?.showsReadTicks == true)
        XCTAssertFalse(repo.chats.first?.showsUnreadTicks == true)
    }

    // MARK: - Mute

    /// `use_default_mute_for` makes `mute_for` meaningless on its own. Reading
    /// `mute_for` alone marks a chat unmuted while the whole scope is muted —
    /// and that is the bug that notifies for chats the user silenced.
    func testMuteResolvesThroughTheScopeDefault() {
        let repo = repo([chat(42, "Anna", order: 10)])
        XCTAssertFalse(repo.chats.first?.isMuted == true)

        repo.apply(.updateScopeNotificationSettings(UpdateScopeNotificationSettings(
            notificationSettings: UpdateFixtures.scopeSettings(muteFor: 2_147_483_647),
            scope: .notificationSettingsScopePrivateChats)))

        XCTAssertTrue(repo.chats.first?.isMuted == true,
                      "a chat on scope defaults must follow a muted scope")
    }

    /// An explicit per-chat setting wins over the scope.
    func testExplicitChatSettingOverridesTheScope() {
        let repo = repo([chat(42, "Anna", order: 10, muted: true)])
        XCTAssertTrue(repo.chats.first?.isMuted == true)
    }

    // MARK: - Drafts

    func testDraftReplacesThePreview() {
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1), chatId: 42, senderUserId: 42,
            content: UpdateFixtures.text("their last message"))
        let repo = repo([chat(42, "Anna", order: 10, last: message)])
        XCTAssertEqual(repo.chats.first?.preview, "their last message")

        repo.apply(.updateChatDraftMessage(UpdateChatDraftMessage(
            chatId: 42,
            draftMessage: UpdateFixtures.draft("half-typed reply"),
            positions: [UpdateFixtures.position(order: 10)])))

        XCTAssertEqual(repo.chats.first?.preview, "half-typed reply")
        XCTAssertTrue(repo.chats.first?.hasDraft == true)
    }

    // MARK: - Send confirmation

    /// `updateMessageSendSucceeded` replaces the whole object — "almost any
    /// field can be different" — so the preview must be rebuilt from the new
    /// message rather than patched.
    func testSendConfirmationReplacesTheLastMessage() {
        let temporary = UpdateFixtures.temporaryMessageId(3)
        let pending = UpdateFixtures.message(
            id: temporary, chatId: 42, senderUserId: 1,
            content: UpdateFixtures.text("sending…"), isOutgoing: true)
        let repo = repo([chat(42, "Anna", order: 10, last: pending)])

        let confirmed = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(3), chatId: 42, senderUserId: 1,
            content: UpdateFixtures.text("sent for real"), isOutgoing: true)
        repo.apply(UpdateFixtures.sendSucceeded(message: confirmed, oldMessageId: temporary))

        XCTAssertEqual(repo.chats.first?.preview, "sent for real")
    }

    // MARK: - Counters

    func testUnreadCountsTrackTheMainListOnly() {
        let repo = repo([chat(42, "Anna", order: 10)])
        repo.apply(.updateUnreadMessageCount(UpdateUnreadMessageCount(
            chatList: .chatListArchive, unreadCount: 99, unreadUnmutedCount: 99)))
        XCTAssertEqual(repo.totalUnreadCount, 0, "archive must not feed the notch badge")

        repo.apply(.updateUnreadMessageCount(UpdateUnreadMessageCount(
            chatList: .chatListMain, unreadCount: 12, unreadUnmutedCount: 7)))
        XCTAssertEqual(repo.totalUnreadCount, 7, "the badge counts unmuted chats")
    }
}
