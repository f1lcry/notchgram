import SwiftUI

/// What lives inside the slab. One of two things: the login flow, or the client.
struct PanelRootView: View {
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
    let geometry: NotchGeometry
    let mediaViewer: MediaViewerState
    /// Raises/clears one hold reason, so typing a code with the pointer parked
    /// outside the panel does not collapse it mid-entry.
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    var body: some View {
        Group {
            if session.authState == .ready {
                ClientView(
                    session: session,
                    chatRepo: chatRepo,
                    messageRepo: messageRepo,
                    fileStore: fileStore,
                    folders: folders,
                    search: search,
                    settings: settings,
                    loginItem: loginItem,
                    onPanelSizeChange: onPanelSizeChange,
                    shared: shared,
                    panelState: panelState,
                    mediaViewer: mediaViewer,
                    setPin: setPin)
            } else {
                AuthView(session: session, onFocusChange: { setPin(.authFocus, $0) })
                    // The auth tree is swapped out wholesale on login — the
                    // falling focus edge never fires, so release on teardown.
                    .onDisappear { setPin(.authFocus, false) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Translucent base coat: the slab's glass backdrop shows through it.
        .background(Theme.Palette.background)
        .foregroundStyle(Theme.Palette.textPrimary)
    }
}
