import SwiftUI

/// Search box at the top of the chat list.
struct ChatSearchField: View {
    let search: ChatSearch
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.textTertiary)

            TextField(L10n.s("Search", "Поиск"), text: Binding(
                get: { search.query },
                set: { search.query = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($isFocused)
                // Typing a search with the pointer parked outside must not
                // collapse the panel mid-word. The reason clears on the
                // falling focus edge and on teardown — whichever comes first.
                .onChange(of: isFocused) { _, focused in setPin(.searchFocus, focused) }
                .onDisappear { setPin(.searchFocus, false) }
                .accessibilityIdentifier("search-field")

            if search.isSearching {
                ProgressView().controlSize(.mini)
            } else if search.isActive {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search-clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .insetGlass(cornerRadius: 8, focused: isFocused)
        .animation(Theme.Motion.quick, value: isFocused)
    }
}
