import XCTest
import TDLibKit
@testable import NotchGram

/// Replays the update sequences that decide chat-list order.
///
/// This is the offline half of L2. Telegram's test-DC login is broken
/// server-side, so there is no automated way to get real chats moving — but the
/// ordering rules are pure functions over the inbound stream, and these are
/// exactly the sequences that are hard to provoke on demand and easy to get
/// wrong.
final class ChatOrderIndexTests: XCTestCase {

    private func chat(_ id: Int64, order: Int64, pinned: Bool = false) -> Update {
        UpdateFixtures.newChat(UpdateFixtures.chat(
            id: id,
            title: "Chat \(id)",
            positions: [UpdateFixtures.position(order: order, isPinned: pinned)]))
    }

    private func apply(_ updates: [Update], to index: inout ChatOrderIndex) {
        for update in updates {
            guard let (chatId, positions) = ChatOrderIndex.positions(from: update) else { continue }
            index.apply(chatId: chatId, positions: positions)
        }
    }

    // MARK: - Ordering

    func testSortsByOrderDescending() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 10), chat(2, order: 30), chat(3, order: 20)], to: &index)
        XCTAssertEqual(index.orderedChatIds, [2, 3, 1])
    }

    /// `order` is a `TdInt64`, which is `Hashable` but **not** `Comparable`, and
    /// it decodes from a JSON *string*. Sorting anything but `.rawValue` either
    /// fails to compile or sorts lexicographically — and lexicographic order
    /// puts "9" above "10", which looks almost right until a chat list grows.
    func testSortsNumericallyNotLexicographically() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 9), chat(2, order: 10), chat(3, order: 100)], to: &index)
        XCTAssertEqual(index.orderedChatIds, [3, 2, 1])
    }

    func testPinnedChatsComeFirst() {
        var index = ChatOrderIndex()
        apply([
            chat(1, order: 100),
            chat(2, order: 10, pinned: true),
            chat(3, order: 50),
        ], to: &index)
        XCTAssertEqual(index.orderedChatIds, [2, 1, 3])
        XCTAssertEqual(index.pinnedChatIds, [2])
        XCTAssertTrue(index.isPinned(2))
        XCTAssertFalse(index.isPinned(1))
    }

    /// Ties must not depend on dictionary iteration order, or the list reshuffles
    /// itself between launches for no visible reason.
    func testTiesAreBrokenDeterministically() {
        var first = ChatOrderIndex()
        var second = ChatOrderIndex()
        apply([chat(7, order: 5), chat(9, order: 5), chat(8, order: 5)], to: &first)
        apply([chat(8, order: 5), chat(7, order: 5), chat(9, order: 5)], to: &second)
        XCTAssertEqual(first.orderedChatIds, second.orderedChatIds)
        XCTAssertEqual(first.orderedChatIds, [9, 8, 7])
    }

    // MARK: - The traps

    /// The one the plan calls out by name: TDLib may send
    /// `updateChatLastMessage` **instead of** `updateChatPosition`, carrying its
    /// own positions array. Handling it anywhere else than the shared path means
    /// a chat that receives a message does not move.
    func testChatLastMessageAlsoReordersTheList() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 10), chat(2, order: 20)], to: &index)
        XCTAssertEqual(index.orderedChatIds, [2, 1])

        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(5),
            chatId: 1,
            senderUserId: 42,
            content: UpdateFixtures.text("hello"))
        apply([UpdateFixtures.chatLastMessage(
            chatId: 1,
            lastMessage: message,
            positions: [UpdateFixtures.position(order: 99)])], to: &index)

        XCTAssertEqual(index.orderedChatIds, [1, 2])
    }

    /// `updateChatDraftMessage` is the third carrier of the same information.
    func testDraftMessageAlsoReordersTheList() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 10), chat(2, order: 20)], to: &index)
        index.apply(chatId: 1, positions: [UpdateFixtures.position(order: 50)])
        XCTAssertEqual(index.orderedChatIds, [1, 2])
    }

    /// `order == 0` means "not in this list". Treating it as a very small order
    /// leaves archived and deleted chats pinned to the bottom of the list
    /// forever.
    func testZeroOrderRemovesTheChat() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 10), chat(2, order: 20)], to: &index)
        index.apply(chatId: 2, positions: [UpdateFixtures.position(order: 0)])
        XCTAssertEqual(index.orderedChatIds, [1])
        XCTAssertNil(index.position(of: 2))
    }

    /// A positions array that does not mention this list says *nothing* about
    /// it. `updateChatPosition` carries one position for one list, and the
    /// last-message/draft updates may carry partial sets — treating absence as
    /// removal (Session 1's reading) drained every other list: chats vanished
    /// from folders on each main-list bump and vice versa. A chat leaves a
    /// list only via an explicit `order == 0` for that list.
    func testPositionsForAnotherListLeaveTheChatAlone() {
        var index = ChatOrderIndex()
        apply([chat(1, order: 10), chat(2, order: 20)], to: &index)
        index.apply(
            chatId: 2,
            positions: [UpdateFixtures.position(order: 20, list: .chatListArchive)])
        XCTAssertEqual(index.orderedChatIds, [2, 1])

        // An empty array — updateChatLastMessage with unchanged positions —
        // is equally silent.
        index.apply(chatId: 2, positions: [])
        XCTAssertEqual(index.orderedChatIds, [2, 1])
    }

    /// An index built for a folder must ignore main-list positions entirely,
    /// or every folder tab shows the same chats.
    func testIndexIgnoresOtherLists() {
        var folder = ChatOrderIndex(list: .chatListFolder(ChatListFolder(chatFolderId: 7)))
        folder.apply(chatId: 1, positions: [UpdateFixtures.position(order: 10)])
        XCTAssertTrue(folder.orderedChatIds.isEmpty)

        folder.apply(chatId: 1, positions: [
            UpdateFixtures.position(order: 10),
            UpdateFixtures.position(
                order: 5, list: .chatListFolder(ChatListFolder(chatFolderId: 7))),
        ])
        XCTAssertEqual(folder.orderedChatIds, [1])
    }

    func testApplyReportsWhetherTheOrderChanged() {
        var index = ChatOrderIndex()
        XCTAssertTrue(index.apply(chatId: 1, positions: [UpdateFixtures.position(order: 10)]))
        XCTAssertFalse(index.apply(chatId: 1, positions: [UpdateFixtures.position(order: 10)]))
        XCTAssertTrue(index.apply(chatId: 2, positions: [UpdateFixtures.position(order: 20)]))
    }

    func testUnrelatedUpdatesCarryNoPositions() {
        XCTAssertNil(ChatOrderIndex.positions(from: UpdateFixtures.connectionState(
            .connectionStateReady)))
        XCTAssertNil(ChatOrderIndex.positions(from: UpdateFixtures.newMessage(
            UpdateFixtures.message(
                id: 1, chatId: 1, senderUserId: 1, content: UpdateFixtures.text("x")))))
    }

    // MARK: - Fixture sanity

    /// Server ids are `server_id << 20`. This is the test the send pipeline uses
    /// to tell a confirmed message from an optimistic one, so the fixtures have
    /// to model it correctly or every send test is vacuous.
    func testFixtureMessageIdsModelTheServerIdShift() {
        XCTAssertEqual(UpdateFixtures.serverMessageId(3) % 1_048_576, 0)
        XCTAssertNotEqual(UpdateFixtures.temporaryMessageId(3) % 1_048_576, 0)
    }

    /// `use_default_mute_for` makes `mute_for` meaningless on its own — a naive
    /// reader notifies for muted chats.
    func testFixtureMuteFlagsAreConsistent() {
        let muted = UpdateFixtures.notificationSettings(isMuted: true)
        XCTAssertFalse(muted.useDefaultMuteFor)
        XCTAssertGreaterThan(muted.muteFor, 0)

        let normal = UpdateFixtures.notificationSettings(isMuted: false)
        XCTAssertTrue(normal.useDefaultMuteFor)
    }
}
