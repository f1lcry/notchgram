import SwiftUI

/// Chat folders as a tab strip above the list.
///
/// The main list is a tab like any other and sits at TDLib's
/// `main_chat_list_position` rather than always first — Telegram lets the user
/// move "All Chats", and putting it first regardless is a small but constant
/// wrongness.
///
/// Selection is one glass pill that *slides* between tabs
/// (`matchedGeometryEffect`) instead of teleporting — the panel's signature
/// "everything is one liquid surface" move.
struct FolderTabsView: View {
    let folders: ChatFolders
    var onSelect: (Int?) -> Void

    @Namespace private var pillNamespace

    var body: some View {
        if folders.hasFolders {
            ScrollViewReader { proxy in
                tabStrip
                    // Selecting a tab that is off the strip's edge (folders past
                    // the panel's width) must bring it into view, or the
                    // highlight is invisible and the strip looks unresponsive.
                    .onChange(of: folders.selectedFolderId) { _, selected in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(selected ?? -1, anchor: .center)
                        }
                    }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(folders.tabs) { tab in
                        Button {
                            onSelect(tab.folderId)
                        } label: {
                            let isSelected = folders.selectedFolderId == tab.folderId
                            HStack(spacing: 4) {
                                Text(tab.folderId == nil
                                    ? L10n.s("All Chats", "Все чаты")
                                    : tab.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                if tab.unreadCount > 0 {
                                    Text(ChatRowView.badgeText(tab.unreadCount))
                                        .font(.system(size: 9, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(Color.black.opacity(0.8))
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 14, minHeight: 14)
                                        .background(Theme.Palette.accent, in: .capsule)
                                        .contentTransition(.numericText())
                                        .animation(Theme.Motion.quick, value: tab.unreadCount)
                                }
                            }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(Theme.Palette.surfaceSelected)
                                            .overlay(
                                                Capsule().strokeBorder(
                                                    Theme.Palette.hairline, lineWidth: 1))
                                            .matchedGeometryEffect(
                                                id: "folder-pill", in: pillNamespace)
                                    }
                                }
                                .foregroundStyle(
                                    isSelected
                                        ? Theme.Palette.textPrimary
                                        : Theme.Palette.textSecondary)
                                // Unselected tabs have a .clear background, and
                                // a .plain Button only hits opaque pixels — the
                                // tab was clickable on its glyphs and badge
                                // alone. Full strip height + explicit shape.
                                .frame(maxHeight: .infinity)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("folder-tab-\(tab.id)")
                    }
                }
                .padding(.horizontal, 6)
                .animation(Theme.Motion.pill, value: folders.selectedFolderId)
            }
            .scrollIndicators(.never)
            .frame(height: 28)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Palette.separator).frame(height: 1)
            }
    }
}
