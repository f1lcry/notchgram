import Foundation
import Observation
@preconcurrency import TDLibKit

/// One tab in the chat-list tab bar.
public struct ChatFolderTab: Identifiable, Equatable, Hashable, Sendable {
    /// `nil` is the main list, which is a tab like any other.
    public let folderId: Int?
    public let title: String
    public var unreadCount: Int

    public var id: Int { folderId ?? -1 }

    public var chatList: ChatList {
        folderId.map { .chatListFolder(ChatListFolder(chatFolderId: $0)) } ?? .chatListMain
    }
}

/// Chat folders, as Telegram delivers them.
///
/// Three things here are easy to get wrong, and all three are silent:
///
/// - The type is `chatFolder*`, not `chatFilter*`. The old spelling is entirely
///   gone from 1.8.66.
/// - `updateChatFolders` carries the **whole** tab bar plus
///   `main_chat_list_position`, so the main list is inserted at that index
///   rather than always first.
/// - A folder's contents come from `loadChats(chatListFolder(id))` and the same
///   position sorting as the main list — **not** from `included_chat_ids`, which
///   are the folder's *rules*, not its membership.
@MainActor
@Observable
public final class ChatFolders: TelegramUpdateSink {
    public private(set) var tabs: [ChatFolderTab] = []
    /// Which tab is showing. `nil` means the main list.
    public var selectedFolderId: Int?

    private var indexes: [Int: ChatOrderIndex] = [:]
    private var mainPosition = 0
    /// Unread-chat counts per list, keyed by folder id (`nil` = main), fed by
    /// `updateUnreadChatCount`. Kept outside `tabs` so a tab rebuild cannot
    /// zero them.
    private var unreadByFolder: [Int?: Int] = [:]
    private weak var client: TDClient?

    public init() {}

    public func attach(client: TDClient) {
        self.client = client
    }

    public var hasFolders: Bool { tabs.count > 1 }

    public func index(for folderId: Int?) -> ChatOrderIndex? {
        folderId.flatMap { indexes[$0] }
    }

    public func apply(_ update: Update) {
        switch update {
        case .updateChatFolders(let payload):
            mainPosition = payload.mainChatListPosition
            rebuildTabs(payload.chatFolders)
            for info in payload.chatFolders where indexes[info.id] == nil {
                indexes[info.id] = ChatOrderIndex(
                    list: .chatListFolder(ChatListFolder(chatFolderId: info.id)))
                // Populate eagerly: a tab whose membership only starts loading
                // on first click reads as "my folders are out of sync". The
                // chats arrive as ordinary position updates.
                Task { [weak self] in await self?.loadFolder(info.id) }
            }
            // Drop indexes for folders that no longer exist, or a deleted
            // folder keeps a stale tab's worth of chats resident.
            let live = Set(payload.chatFolders.map(\.id))
            indexes = indexes.filter { live.contains($0.key) }
            if let selected = selectedFolderId, !live.contains(selected) {
                selectedFolderId = nil
            }

        // Folder tabs carry Telegram's unread badge: unmuted chats with
        // unread messages, per list.
        case .updateUnreadChatCount(let payload):
            let key: Int?
            switch payload.chatList {
            case .chatListMain: key = nil
            case .chatListFolder(let folder): key = folder.chatFolderId
            case .chatListArchive: return
            }
            unreadByFolder[key] = payload.unreadUnmutedCount
            if let position = tabs.firstIndex(where: { $0.folderId == key }) {
                tabs[position].unreadCount = payload.unreadUnmutedCount
            }

        default:
            guard let (chatId, positions) = ChatOrderIndex.positions(from: update) else { return }
            for key in indexes.keys {
                indexes[key]?.apply(chatId: chatId, positions: positions)
            }
        }
    }

    /// Asks TDLib to populate a folder. Its chats arrive as position updates,
    /// exactly like the main list.
    public func loadFolder(_ folderId: Int, limit: Int = 40) async {
        guard let client else { return }
        try? await client.loadChats(
            chatList: .chatListFolder(ChatListFolder(chatFolderId: folderId)), limit: limit)
    }

    private func rebuildTabs(_ folders: [ChatFolderInfo]) {
        var built = folders.map { info in
            // The display name is `name.text.text` — a `ChatFolderName`
            // wrapping a `FormattedText`, not a plain string.
            ChatFolderTab(
                folderId: info.id,
                title: info.name.text.text,
                unreadCount: unreadByFolder[info.id] ?? 0)
        }
        let main = ChatFolderTab(
            folderId: nil, title: "All Chats", unreadCount: unreadByFolder[nil] ?? 0)
        let position = max(0, min(mainPosition, built.count))
        built.insert(main, at: position)
        tabs = built
    }
}
