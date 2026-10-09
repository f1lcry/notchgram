import Foundation
@preconcurrency import TDLibKit

/// Chat-list ordering — the single path every ordering update funnels through.
///
/// TDLib does not have one "the chat moved" update. `updateChatPosition`,
/// `updateChatLastMessage` and `updateChatDraftMessage` each carry their own
/// positions, and TDLib may send the latter two **instead of** the first. Three
/// separate handlers is how a chat list silently stops matching Telegram:
/// everything here goes through `apply(chatId:positions:)`.
///
/// Rules, each of which is a bug if broken:
/// - Sort by `(order, chatId)` **descending**. `order` is a `TdInt64`, which is
///   `Hashable` but not `Comparable`, so the sort must use `.rawValue`.
/// - `order == 0` means "not in this list" — remove, do not sort to the bottom.
/// - Pinned chats are ordinary entries with `isPinned == true`, not a separate
///   array; they sort above the rest because TDLib gives them a higher order,
///   but the flag is what the UI groups on.
/// - Read placement from `chat.positions`, never from `chat.chatLists` — the
///   latter says which lists a chat belongs to, not where it sits in them.
public struct ChatOrderIndex: Sendable, Equatable {
    /// The list this index describes. One index per rendered list (main, or a
    /// folder); a chat can legitimately appear in several.
    public let list: ChatList

    private var entries: [Int64: ChatPosition] = [:]
    private var order: [Int64] = []

    public init(list: ChatList = .chatListMain) {
        self.list = list
    }

    /// Chat ids in display order: pinned first (in their own order), then the
    /// rest.
    public var orderedChatIds: [Int64] { order }

    public var pinnedChatIds: [Int64] {
        order.filter { entries[$0]?.isPinned == true }
    }

    public var count: Int { entries.count }

    public func position(of chatId: Int64) -> ChatPosition? { entries[chatId] }

    public func isPinned(_ chatId: Int64) -> Bool { entries[chatId]?.isPinned == true }

    /// Applies the positions array carried by *any* of the three updates.
    /// Returns true when the visible order changed, so a caller can skip
    /// redrawing a long list for a no-op.
    ///
    /// A list this array does not mention is **untouched** — never treated as
    /// a removal. `updateChatPosition` carries exactly one position for one
    /// list, and `updateChatLastMessage`/`updateChatDraftMessage` may carry a
    /// partial (or empty) set; inferring "absent ⇒ removed" from any of them
    /// silently drained every *other* list — chats vanished from folders on
    /// each main-list bump, and from the main list on each folder bump.
    /// Leaving a list always arrives explicitly as `order == 0` for that list.
    @discardableResult
    public mutating func apply(chatId: Int64, positions: [ChatPosition]) -> Bool {
        guard let position = positions.first(where: { $0.list == list }) else {
            return false
        }
        let before = order

        if position.order.rawValue == 0 {
            entries.removeValue(forKey: chatId)
        } else {
            entries[chatId] = position
        }

        resort()
        return order != before
    }

    @discardableResult
    public mutating func remove(chatId: Int64) -> Bool {
        guard entries.removeValue(forKey: chatId) != nil else { return false }
        resort()
        return true
    }

    private mutating func resort() {
        order = entries
            .sorted { lhs, rhs in
                // Pinned above unpinned regardless of order value: TDLib is
                // consistent about giving pinned chats a higher order, but the
                // UI contract is the flag, and a server that disagrees should
                // not scatter pinned chats through the list.
                if lhs.value.isPinned != rhs.value.isPinned { return lhs.value.isPinned }
                if lhs.value.order.rawValue != rhs.value.order.rawValue {
                    return lhs.value.order.rawValue > rhs.value.order.rawValue
                }
                // Ties broken by id, descending, so the order is total and
                // stable rather than dependent on dictionary iteration.
                return lhs.key > rhs.key
            }
            .map(\.key)
    }
}

extension ChatOrderIndex {
    /// Extracts the positions array from whichever update carried it. Returning
    /// nil means "this update says nothing about ordering".
    public static func positions(from update: Update) -> (chatId: Int64, positions: [ChatPosition])? {
        switch update {
        case .updateChatPosition(let payload):
            (payload.chatId, [payload.position])
        case .updateChatLastMessage(let payload):
            (payload.chatId, payload.positions)
        case .updateChatDraftMessage(let payload):
            (payload.chatId, payload.positions)
        case .updateNewChat(let payload):
            (payload.chat.id, payload.chat.positions)
        default:
            nil
        }
    }
}
