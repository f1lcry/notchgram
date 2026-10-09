import SwiftUI

/// The signed-in client: chat list on the left, conversation on the right.
///
/// Telegram Desktop's split, at the panel's scale (P3).
struct ClientView: View {
    let session: TelegramSession
    let chatRepo: ChatRepo
    let messageRepo: MessageRepo
    let fileStore: FileStore
    let folders: ChatFolders
    let search: ChatSearch
    let settings: PanelSettings
    let loginItem: LoginItem
    var onPanelSizeChange: (CGSize) -> Void
    let shared: PanelSharedState
    let panelState: PanelState
    let mediaViewer: MediaViewerState
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(state: session.connectionState)

            HStack(spacing: 0) {
                ChatListView(
                    repo: chatRepo,
                    folders: folders,
                    search: search,
                    fileStore: fileStore,
                    shared: shared,
                    onSelect: {
                        shared.openChatId = $0
                        shared.activePane = .conversation
                    },
                    setPin: setPin)

                Rectangle()
                    .fill(Theme.Palette.separator)
                    .frame(width: 1)

                rightPane
            }
        }
        .overlay {
            if mediaViewer.isPresented {
                MediaViewerView(
                    viewer: mediaViewer,
                    fileStore: fileStore,
                    setPin: setPin)
            }
        }
        .task { await chatRepo.loadMore() }
    }

    @ViewBuilder
    private var rightPane: some View {
        Group {
            switch shared.activePane {
            case .settings:
                SettingsView(
                    settings: settings,
                    loginItem: loginItem,
                    session: session,
                    onPanelSizeChange: onPanelSizeChange,
                    onClose: { shared.activePane = .conversation })
            case .profile:
                ProfileView(session: session, onClose: { shared.activePane = .conversation })
            case .conversation:
                conversation
            }
        }
        .id(shared.activePane)
        // Panes breathe in rather than blink: a whisper of scale under the
        // fade — never a slide, nothing inside the slab travels sideways.
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .animation(Theme.Motion.pane, value: shared.activePane)
    }

    @ViewBuilder
    private var conversation: some View {
        // The cache, not the visible list: a chat opened from search results or
        // a folder tab may not be in the main list at all.
        if let chatId = shared.openChatId,
           let summary = chatRepo.cachedSummary(id: chatId) {
            ConversationView(
                summary: summary,
                repo: messageRepo,
                fileStore: fileStore,
                shared: shared,
                panelState: panelState,
                mediaViewer: mediaViewer,
                setPin: setPin,
                onToggleMute: { [chatRepo] in
                    Task { await chatRepo.toggleMute(chatId: chatId) }
                })
                // Fresh view — fresh scroll view — per chat. Without this the
                // ScrollView instance survived chat switches: chat A's offset
                // and `isNearBottom` leaked into chat B, `.initialOffset`
                // anchoring never re-fired, and rapid switching landed
                // mid-chat at whatever place the size-change math produced.
                .id(summary.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.04), in: .circle)
                    .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                Text(L10n.s("Select a chat", "Выберите чат"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("no-chat-selected")
        }
    }
}
