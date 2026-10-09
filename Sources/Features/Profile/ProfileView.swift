import SwiftUI

/// The signed-in account, at a glance.
struct ProfileView: View {
    let session: TelegramSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                PanelIconButton(systemName: "xmark", iconSize: 11, action: onClose)
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 8)
            .background(Theme.Palette.surfaceRaised)

            if let me = session.me {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Theme.Palette.avatarColor(for: me.id))
                            .frame(width: 72, height: 72)
                        Text(initials(me.firstName, me.lastName))
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text("\(me.firstName) \(me.lastName)".trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let username = me.usernames?.activeUsernames.first {
                        Text("@\(username)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    if !me.phoneNumber.isEmpty {
                        Text("+\(me.phoneNumber)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(.top, 24)
            } else {
                Text("Not signed in")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.top, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.surface)
        .accessibilityIdentifier("profile-view")
    }

    private func initials(_ first: String, _ last: String) -> String {
        [first, last].compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
