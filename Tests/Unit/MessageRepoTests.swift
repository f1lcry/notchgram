import XCTest
import TDLibKit
@testable import NotchGram

/// Replays conversation sequences through the real `MessageRepo`.
///
/// The send pipeline and the delete semantics are the two places where getting
/// it subtly wrong produces a bug nobody can reproduce: a row that flickers on
/// confirmation, or a message that vanishes and comes back.
@MainActor
final class MessageRepoTests: XCTestCase {

    private let chatId: Int64 = 501

    /// `open` sets the window even with no client attached — the TDLib calls it
    /// would make are guarded — which is what makes the sink testable offline.
    private func openRepo() async -> MessageRepo {
        let repo = MessageRepo()
        await repo.open(chatId: chatId)
        return repo
    }

    private func incoming(_ id: Int64, _ text: String, date: Int = 1_700_000_000) -> Update {
        UpdateFixtures.newMessage(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(id),
            chatId: chatId, senderUserId: 77,
            content: UpdateFixtures.text(text), date: date))
    }

    private func outgoing(_ id: Int64, _ text: String, date: Int = 1_700_000_000) -> Update {
        UpdateFixtures.newMessage(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(id),
            chatId: chatId, senderUserId: 1,
            content: UpdateFixtures.text(text), isOutgoing: true, date: date))
    }

    // MARK: - Window

    func testMessagesAreOrderedOldestFirst() async {
        let repo = await openRepo()
        repo.apply(incoming(3, "third", date: 300))
        repo.apply(incoming(1, "first", date: 100))
        repo.apply(incoming(2, "second", date: 200))
        XCTAssertEqual(repo.items.map(\.text), ["first", "second", "third"])
    }

    /// The panel shows one conversation; holding every visited chat resident is
    /// how a background agent quietly grows to a gigabyte.
    func testOpeningAnotherChatClearsTheWindow() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "hello"))
        XCTAssertEqual(repo.items.count, 1)

        await repo.open(chatId: 999)
        XCTAssertTrue(repo.items.isEmpty)
        XCTAssertEqual(repo.chatId, 999)
    }

    func testMessagesForOtherChatsAreIgnored() async {
        let repo = await openRepo()
        repo.apply(UpdateFixtures.newMessage(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1),
            chatId: 12345, senderUserId: 77, content: UpdateFixtures.text("elsewhere"))))
        XCTAssertTrue(repo.items.isEmpty)
    }

    /// Deep scroll-back slides the window: history pages are merged without an
    /// inline trim (Session 4 never trimmed this direction at all — the
    /// fast-scroll crash), and `trimNewestOverflow` then drops the rows far
    /// below the viewport and marks the gap to the live bottom re-loadable.
    func testScrollBackTrimsTheNewestRowsAndMarksTheGap() async {
        let repo = await openRepo()
        let page = (1...(MessageRepo.maxLiveItems + 20)).map { id in
            UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(Int64(id)),
                chatId: chatId, senderUserId: 77,
                content: UpdateFixtures.text("m\(id)"), date: id)
        }
        repo.ingest(page)
        XCTAssertEqual(repo.items.count, MessageRepo.maxLiveItems + 20)

        repo.trimNewestOverflow()
        XCTAssertEqual(repo.items.count, MessageRepo.maxLiveItems)
        XCTAssertTrue(repo.hasMoreNewer)
        XCTAssertEqual(repo.items.last?.text, "m\(MessageRepo.maxLiveItems)",
                       "the newest rows are the ones dropped")
        XCTAssertEqual(repo.items.first?.text, "m1", "the reading window stays put")
    }

    /// A row still in flight is never trimmed away.
    func testTrimNewestSparesPendingRows() async {
        let repo = await openRepo()
        let page = (1...(MessageRepo.maxLiveItems + 5)).map { id in
            UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(Int64(id)),
                chatId: chatId, senderUserId: 77,
                content: UpdateFixtures.text("m\(id)"), date: id)
        }
        repo.ingest(page)
        repo.insertOptimistic(text: "in flight", sendingId: 9, chatId: chatId)

        repo.trimNewestOverflow()
        XCTAssertEqual(repo.items.count, MessageRepo.maxLiveItems + 6,
                       "trim waits while the drop range holds a pending row")
        XCTAssertFalse(repo.hasMoreNewer)
    }

    /// Detached from the live bottom, an arriving message is NOT adjacent to
    /// the loaded window — appending it would splice a gap into history.
    func testLiveAppendsAreIgnoredWhileDetachedFromTheBottom() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "one", date: 100))
        repo.hasMoreNewer = true
        repo.apply(incoming(2, "two", date: 200))
        XCTAssertEqual(repo.items.map(\.text), ["one"])

        repo.hasMoreNewer = false
        repo.apply(incoming(3, "three", date: 300))
        XCTAssertEqual(repo.items.map(\.text), ["one", "three"])
    }

    // MARK: - Send confirmation

    /// The row keeps its identity across confirmation.
    ///
    /// `updateMessageSendSucceeded` hands back a different message id and, in
    /// TDLib's own words, "almost any field can be different". Re-keying the row
    /// on the new id makes SwiftUI tear it down and build a new one — a visible
    /// flicker in the middle of a conversation — so the key is the correlation
    /// token, and only the contents are replaced.
    func testSendConfirmationKeepsTheRowIdentityAndReplacesContent() async {
        let repo = await openRepo()
        let temporaryId = UpdateFixtures.temporaryMessageId(7)

        repo.apply(UpdateFixtures.newMessage(UpdateFixtures.message(
            id: temporaryId, chatId: chatId, senderUserId: 1,
            content: UpdateFixtures.text("sending…"), isOutgoing: true,
            sendingState: .messageSendingStatePending(
                MessageSendingStatePending(sendingId: 42)))))

        let keyBefore = repo.items.first?.id
        XCTAssertEqual(repo.items.first?.status, .pending)

        let confirmedId = UpdateFixtures.serverMessageId(7)
        repo.apply(UpdateFixtures.sendSucceeded(
            message: UpdateFixtures.message(
                id: confirmedId, chatId: chatId, senderUserId: 1,
                content: UpdateFixtures.text("sent for real"), isOutgoing: true),
            oldMessageId: temporaryId))

        XCTAssertEqual(repo.items.count, 1, "confirmation must not duplicate the row")
        XCTAssertEqual(repo.items.first?.id, keyBefore, "the row identity must survive")
        XCTAssertEqual(repo.items.first?.text, "sent for real")
        XCTAssertEqual(repo.items.first?.status, .sent)
        XCTAssertEqual(repo.items.first?.messageId, confirmedId)
        XCTAssertTrue(repo.items.first?.hasServerId == true)
    }

    /// TDLib's local echo (`updateNewMessage`, pending state) can arrive before
    /// the `sendMessage` response has bound the temporary id. The echo carries
    /// the correlation token in `messageSendingStatePending.sendingId`, and
    /// `merge` must fold it into the optimistic row — inserting it produced a
    /// duplicate outgoing message: one row stuck on the clock forever, one
    /// confirmed, until the chat was reopened.
    func testLocalEchoBeforeSendResponseDoesNotDuplicateTheRow() async {
        let repo = await openRepo()
        repo.insertOptimistic(text: "hi", sendingId: 42, chatId: chatId)
        XCTAssertEqual(repo.items.count, 1)

        let temporaryId = UpdateFixtures.temporaryMessageId(7)
        repo.apply(UpdateFixtures.newMessage(UpdateFixtures.message(
            id: temporaryId, chatId: chatId, senderUserId: 1,
            content: UpdateFixtures.text("hi"), isOutgoing: true,
            sendingState: .messageSendingStatePending(
                MessageSendingStatePending(sendingId: 42)))))

        XCTAssertEqual(repo.items.count, 1, "the echo must fold into the optimistic row")
        XCTAssertEqual(repo.items.first?.id, .local(42), "the row identity must survive")
        XCTAssertEqual(repo.items.first?.status, .pending)
        XCTAssertEqual(repo.items.first?.messageId, temporaryId)

        let confirmedId = UpdateFixtures.serverMessageId(7)
        repo.apply(UpdateFixtures.sendSucceeded(
            message: UpdateFixtures.message(
                id: confirmedId, chatId: chatId, senderUserId: 1,
                content: UpdateFixtures.text("hi"), isOutgoing: true),
            oldMessageId: temporaryId))

        XCTAssertEqual(repo.items.count, 1, "confirmation must not duplicate the row")
        XCTAssertEqual(repo.items.first?.id, .local(42))
        XCTAssertEqual(repo.items.first?.status, .sent)
        XCTAssertEqual(repo.items.first?.messageId, confirmedId)
    }

    func testSendFailureIsSurfacedWithItsReason() async {
        let repo = await openRepo()
        let temporaryId = UpdateFixtures.temporaryMessageId(8)
        repo.apply(UpdateFixtures.newMessage(UpdateFixtures.message(
            id: temporaryId, chatId: chatId, senderUserId: 1,
            content: UpdateFixtures.text("nope"), isOutgoing: true,
            sendingState: .messageSendingStatePending(
                MessageSendingStatePending(sendingId: 43)))))

        repo.apply(.updateMessageSendFailed(UpdateMessageSendFailed(
            error: TDLibKit.Error(code: 400, message: "NETWORK_UNAVAILABLE"),
            message: UpdateFixtures.message(
                id: temporaryId, chatId: chatId, senderUserId: 1,
                content: UpdateFixtures.text("nope"), isOutgoing: true),
            oldMessageId: temporaryId)))

        XCTAssertEqual(repo.items.first?.status, .failed("NETWORK_UNAVAILABLE"))
    }

    /// A temporary id is not `server_id << 20`; a confirmed one is. This is the
    /// test the whole optimistic pipeline rests on.
    func testTemporaryIdsAreDistinguishableFromServerIds() async {
        let repo = await openRepo()
        repo.apply(UpdateFixtures.newMessage(UpdateFixtures.message(
            id: UpdateFixtures.temporaryMessageId(5), chatId: chatId, senderUserId: 1,
            content: UpdateFixtures.text("x"), isOutgoing: true)))
        XCTAssertFalse(repo.items.first?.hasServerId == true)
    }

    // MARK: - Delete

    /// `from_cache == true` means TDLib evicted the message from its cache — it
    /// can come back. Treating that as a delete makes messages disappear from a
    /// conversation the user is reading.
    func testCacheEvictionIsNotADelete() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "still here"))

        repo.apply(.updateDeleteMessages(UpdateDeleteMessages(
            chatId: chatId,
            fromCache: true,
            isPermanent: false,
            messageIds: [UpdateFixtures.serverMessageId(1)])))

        XCTAssertEqual(repo.items.count, 1, "a cache eviction must not remove the row")
    }

    func testPermanentDeleteRemovesTheMessage() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "goodbye"))

        repo.apply(.updateDeleteMessages(UpdateDeleteMessages(
            chatId: chatId,
            fromCache: false,
            isPermanent: true,
            messageIds: [UpdateFixtures.serverMessageId(1)])))

        XCTAssertTrue(repo.items.isEmpty)
    }

    // MARK: - Read state

    /// There is no per-message read update. When the outbox marker moves, every
    /// visible outgoing row has to be re-evaluated — not just the newest.
    func testOutboxMarkerReevaluatesEveryOutgoingMessage() async {
        let repo = await openRepo()
        repo.apply(outgoing(1, "one", date: 100))
        repo.apply(outgoing(2, "two", date: 200))
        repo.apply(outgoing(3, "three", date: 300))
        XCTAssertEqual(repo.items.filter(\.isReadByPeer).count, 0)

        repo.apply(.updateChatReadOutbox(UpdateChatReadOutbox(
            chatId: chatId, lastReadOutboxMessageId: UpdateFixtures.serverMessageId(2))))

        XCTAssertEqual(repo.items.filter(\.isReadByPeer).map(\.text), ["one", "two"])
        XCTAssertFalse(repo.items.last?.isReadByPeer == true)
    }

    // MARK: - Read receipts

    /// Records what the repo would report to `viewMessages`.
    @MainActor
    private final class ReadRecorder {
        var batches: [(chatId: Int64, ids: Set<Int64>)] = []
        func attach(to repo: MessageRepo) {
            repo.viewMessagesSender = { [weak self] chatId, ids in
                self?.batches.append((chatId, Set(ids)))
            }
        }
        var allIds: Set<Int64> { batches.reduce(into: []) { $0.formUnion($1.ids) } }
    }

    /// One repo serves every screen's panel, and their view lifecycles
    /// overlap: moving the panel to another screen settles the new view
    /// before the old one unmounts. The old view's `onDisappear` must not
    /// revoke the visibility the new view owns — when it did, the open
    /// conversation silently stopped sending read receipts (the sticky
    /// unread-badge bug).
    func testStaleViewCannotRevokeAnotherViewsVisibility() async {
        let repo = await openRepo()
        let oldView = UUID(), newView = UUID()

        repo.setConversationVisible(true, owner: oldView)
        repo.setConversationVisible(true, owner: newView)
        repo.setConversationVisible(false, owner: oldView)
        XCTAssertTrue(repo.isConversationVisible,
                      "a stale view's onDisappear must not revoke visibility")

        repo.setConversationVisible(false, owner: newView)
        XCTAssertFalse(repo.isConversationVisible,
                       "the owning view can still release it")
    }

    /// Rows noted before the panel settles are reported once it does.
    func testSeenRowsFlushOnceConversationSettles() async throws {
        let repo = await openRepo()
        let recorder = ReadRecorder()
        recorder.attach(to: repo)

        repo.apply(incoming(1, "one", date: 100))
        repo.apply(incoming(2, "two", date: 200))
        repo.noteVisible(UpdateFixtures.serverMessageId(1))
        repo.noteVisible(UpdateFixtures.serverMessageId(2))

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(recorder.batches.isEmpty,
                      "nothing is reported while the panel has not settled")

        repo.setConversationVisible(true, owner: UUID())
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches.first?.chatId, chatId)
        XCTAssertEqual(recorder.allIds,
                       [UpdateFixtures.serverMessageId(1), UpdateFixtures.serverMessageId(2)])
    }

    /// Outgoing rows never generate receipts, whatever the view reports.
    func testOutgoingRowsAreNeverReportedSeen() async throws {
        let repo = await openRepo()
        let recorder = ReadRecorder()
        recorder.attach(to: repo)
        repo.setConversationVisible(true, owner: UUID())

        repo.apply(outgoing(1, "mine"))
        repo.noteVisible(UpdateFixtures.serverMessageId(1))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(recorder.batches.isEmpty)
    }

    /// Switching chats inside the debounce window used to drop the batch on
    /// the floor — a chat visited for under 300 ms stayed unread forever.
    func testSwitchingChatsFlushesPendingReadsImmediately() async {
        let repo = await openRepo()
        let recorder = ReadRecorder()
        recorder.attach(to: repo)
        repo.setConversationVisible(true, owner: UUID())

        repo.apply(incoming(1, "seen", date: 100))
        repo.noteVisible(UpdateFixtures.serverMessageId(1))
        await repo.open(chatId: 999)

        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches.first?.chatId, chatId,
                       "the receipt belongs to the chat that was left")
        XCTAssertEqual(recorder.allIds, [UpdateFixtures.serverMessageId(1)])
    }

    /// Replying claims the chat is read — Telegram's rule. The newest loaded
    /// incoming message is the watermark, so the badge cannot outlive the
    /// user's own answer.
    func testReplyMarksNewestIncomingRead() async {
        let repo = await openRepo()
        let recorder = ReadRecorder()
        recorder.attach(to: repo)

        repo.apply(incoming(1, "question", date: 100))
        repo.apply(incoming(2, "nudge", date: 200))
        repo.apply(outgoing(3, "my answer", date: 300))
        repo.markReadOnReply()

        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.batches.first?.chatId, chatId)
        XCTAssertEqual(recorder.allIds, [UpdateFixtures.serverMessageId(2)],
                       "the newest incoming message is the watermark")
    }

    // MARK: - Edits and content

    func testEditedMessagesAreMarked() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "typo"))
        XCTAssertFalse(repo.items.first?.isEdited == true)

        repo.apply(.updateMessageEdited(UpdateMessageEdited(
            chatId: chatId,
            editDate: 1_700_000_500,
            messageId: UpdateFixtures.serverMessageId(1),
            replyMarkup: nil)))

        XCTAssertTrue(repo.items.first?.isEdited == true)
    }

    func testContentUpdatesReplaceTheBody() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "before"))
        repo.apply(.updateMessageContent(UpdateMessageContent(
            chatId: chatId,
            messageId: UpdateFixtures.serverMessageId(1),
            newContent: UpdateFixtures.text("after"))))
        XCTAssertEqual(repo.items.first?.text, "after")
    }

    // MARK: - Sender names

    /// TDLib delivers `updateUser` before it hands the id over, but a name that
    /// arrives afterwards still has to reach rows already drawn.
    func testLateUserUpdateBackfillsSenderNames() async {
        let repo = await openRepo()
        repo.apply(incoming(1, "hello"))
        XCTAssertEqual(repo.items.first?.senderName, "")

        repo.apply(.updateUser(UpdateUser(user: UpdateFixtures.user(
            id: 77, firstName: "Anna", lastName: "Petrova"))))
        XCTAssertEqual(repo.items.first?.senderName, "Anna Petrova")
    }

    // MARK: - Typing

    /// `updateUserChatAction` does not exist in 1.8.66 — it is `updateChatAction`
    /// carrying a `senderId`. A client written against the old name shows no
    /// typing indicator at all and no error either.
    func testTypingIndicatorTracksChatAction() async {
        let repo = await openRepo()
        repo.apply(.updateUser(UpdateUser(user: UpdateFixtures.user(id: 77, firstName: "Anna"))))

        repo.apply(.updateChatAction(UpdateChatAction(
            action: .chatActionTyping,
            chatId: chatId,
            senderId: .messageSenderUser(MessageSenderUser(userId: 77)),
            topicId: nil)))
        XCTAssertEqual(repo.typingNames, ["Anna"])

        repo.apply(.updateChatAction(UpdateChatAction(
            action: .chatActionCancel,
            chatId: chatId,
            senderId: .messageSenderUser(MessageSenderUser(userId: 77)),
            topicId: nil)))
        XCTAssertTrue(repo.typingNames.isEmpty)
    }
}
