import SwiftUI

/// The chat list.
///
/// `ScrollView` + `LazyVStack`, not `List`: `List` is NSTableView-backed, fights
/// a dark borderless slab for its background, and reuses badly with
/// variable-height rows.
struct ChatListView: View {
    let repo: ChatRepo
    let folders: ChatFolders
    let search: ChatSearch
    let fileStore: FileStore
    let shared: PanelSharedState
    var onSelect: (Int64) -> Void
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    /// Search results replace the list rather than filtering it in place, so it
    /// is always obvious which set is on screen.
    private var visibleChats: [ChatSummary] {
        if search.isActive { return search.results }
        // A folder's membership comes from position updates for that list, not
        // from the folder's inclusion rules.
        if let index = folders.index(for: folders.selectedFolderId) {
            // Pinned state is per list: a folder has its own pinned set, and
            // the baked summary carries the *main* list's flag.
            return repo.summaries(for: index.orderedChatIds).map { summary in
                var summary = summary
                summary.isPinned = index.isPinned(summary.id)
                return summary
            }
        }
        return repo.chats
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            FolderTabsView(folders: folders) { folderId in
                folders.selectedFolderId = folderId
                if let folderId { Task { await folders.loadFolder(folderId) } }
            }
            list
        }
        .frame(width: Theme.Metrics.chatListWidth)
        .background(Theme.Palette.surface)
    }

    /// No raised strip behind it: on the black ground the search field's own
    /// glass is the header, and one less plane means one less seam.
    private var header: some View {
        HStack(spacing: 6) {
            ChatSearchField(search: search, setPin: setPin)
            PanelIconButton(systemName: "person.crop.circle") {
                shared.activePane = shared.activePane == .profile ? .conversation : .profile
            }
            .accessibilityIdentifier("open-profile")

            PanelIconButton(systemName: "gearshape") {
                shared.activePane = shared.activePane == .settings ? .conversation : .settings
            }
            .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if visibleChats.isEmpty, !search.isActive || search.messageResults.isEmpty {
                    emptyState
                } else {
                    // Telegram's two search sections: chats, then messages.
                    if search.isActive, !visibleChats.isEmpty {
                        sectionHeader(L10n.s("Chats", "Чаты"))
                    }
                    ForEach(visibleChats) { summary in
                        // A `Button`, not `.onTapGesture`. Verified on the real
                        // list: a tap gesture on a row inside a ScrollView +
                        // LazyVStack never fires on macOS — the scroll view
                        // claims the click. The panel took key focus and the
                        // selection never changed, which made the whole client
                        // unusable in the least obvious way possible.
                        Button {
                            onSelect(summary.id)
                        } label: {
                            ChatRowView(
                                summary: summary,
                                fileStore: fileStore,
                                isSelected: shared.openChatId == summary.id)
                        }
                        .buttonStyle(.plain)
                    }
                    if search.isActive, !search.messageResults.isEmpty {
                        sectionHeader(L10n.s("Messages", "Сообщения"))
                        ForEach(search.messageResults) { hit in
                            Button {
                                onSelect(hit.chatId)
                            } label: {
                                ChatRowView(
                                    summary: hit.chat,
                                    fileStore: fileStore,
                                    isSelected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Reaching the end asks TDLib for the next window — of
                    // whichever list is showing. The chats themselves arrive
                    // as updates, so this only moves the boundary. Paging is
                    // for the real lists, not for results.
                    if !search.isActive {
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { [selected = folders.selectedFolderId] in
                                    if let selected {
                                        await folders.loadFolder(selected)
                                    } else {
                                        await repo.loadMore()
                                    }
                                }
                            }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("chat-list")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    /// "Loading" and "genuinely empty" look identical if you do not say which.
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if search.isActive {
                Text(L10n.s("Nothing found", "Ничего не найдено"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else if repo.isLoading {
                ProgressView().controlSize(.small)
                Text(L10n.s("Loading chats…", "Загрузка чатов…"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Text(L10n.s("No chats yet", "Пока нет чатов"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
