import SwiftUI

/// The login surface, one screen per authorization state.
///
/// **All thirteen states are modelled**, not just the happy path. That is not
/// completeness for its own sake: `waitRegistration` is the normal outcome for
/// any new number, `waitEmailAddress`/`waitEmailCode` appear on accounts with a
/// login email, and `waitPremiumPurchase` exists in 1.8.66. CP1 is the founder's
/// single interactive login — a state nobody drew is a hang at the one moment
/// there is no second chance.
///
/// Every screen is reachable through DebugBridge's `gotoAuthState`, so all of
/// them can be screenshotted and reviewed without an account.
struct AuthView: View {
    let session: TelegramSession
    /// Set while the composer-equivalent has focus, so the panel stays open
    /// while someone is typing a code with the pointer parked elsewhere.
    var onFocusChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(state: session.connectionState)

            Group {
                switch session.authState {
                case .initializing:
                    AuthProgressScreen(
                        title: "Starting Telegram…",
                        subtitle: "Opening the local database.")

                case .waitPhoneNumber:
                    PhoneEntryScreen(session: session, onFocusChange: onFocusChange)

                case .waitCode(let challenge):
                    CodeEntryScreen(
                        session: session, challenge: challenge, onFocusChange: onFocusChange)

                case .waitPassword(let challenge):
                    PasswordScreen(
                        session: session, challenge: challenge, onFocusChange: onFocusChange)

                case .waitRegistration(let challenge):
                    RegistrationScreen(
                        session: session, challenge: challenge, onFocusChange: onFocusChange)

                case .waitEmailAddress(let allowAppleId, let allowGoogleId):
                    EmailAddressScreen(
                        session: session,
                        allowAppleId: allowAppleId,
                        allowGoogleId: allowGoogleId,
                        onFocusChange: onFocusChange)

                case .waitEmailCode(let challenge):
                    EmailCodeScreen(
                        session: session, challenge: challenge, onFocusChange: onFocusChange)

                case .waitOtherDeviceConfirmation(let link):
                    OtherDeviceScreen(link: link)

                case .waitPremiumPurchase(let challenge):
                    PremiumPurchaseScreen(challenge: challenge)

                case .ready:
                    AuthProgressScreen(title: "Signed in", subtitle: nil)

                case .loggingOut:
                    AuthProgressScreen(
                        title: "Logging out…",
                        subtitle: "Telegram is destroying the local data for this account.")

                case .closing:
                    AuthProgressScreen(title: "Closing…", subtitle: nil)

                case .closed:
                    AuthProgressScreen(
                        title: "Disconnected",
                        subtitle: "Quit and reopen NotchGram to sign in again.")

                case .unsupported(let raw):
                    UnsupportedStateScreen(rawState: raw)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("auth-view")
    }
}

// MARK: - Shared layout

/// One column, centred, with room for a title, a field, an action and an error.
/// Every auth screen uses it so they do not drift apart visually.
struct AuthScaffold<Fields: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var error: TDError?
    var isBusy: Bool = false
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 10) { fields() }
                .frame(maxWidth: 320)

            HStack(spacing: 10) { actions() }
                .frame(maxWidth: 320)

            // Reserved rather than conditional, so the layout does not jump the
            // moment an error appears under a field someone is typing in.
            Text(errorText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.destructive)
                .multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
                .frame(maxWidth: 320)
                .opacity(errorText.isEmpty ? 0 : 1)
                .accessibilityIdentifier("auth-error")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .overlay(alignment: .top) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
                    .accessibilityIdentifier("auth-busy")
            }
        }
    }

    /// A 406 must never be shown — TDLib is explicit that its message must not
    /// be processed or displayed in any way.
    private var errorText: String {
        error?.userFacingMessage ?? ""
    }
}

/// Primary action: solid ice with ink text — the one loud element on an auth
/// screen, because there is exactly one thing to do on each.
struct AuthPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    isEnabled ? AnyShapeStyle(Theme.Palette.accent)
                        : AnyShapeStyle(Color.white.opacity(0.05)),
                    in: .rect(cornerRadius: 9))
                .overlay {
                    if !isEnabled {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.pressable)
        .foregroundStyle(isEnabled ? Color.black.opacity(0.85) : Theme.Palette.textTertiary)
        .animation(Theme.Motion.quick, value: isEnabled)
        .disabled(!isEnabled)
    }
}

struct AuthSecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .insetGlass(cornerRadius: 9)
        }
        .buttonStyle(.pressable)
        .foregroundStyle(isEnabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
        .disabled(!isEnabled)
    }
}

/// Plain field on the dark slab. `.textFieldStyle(.plain)` matters: the stock
/// bordered style paints a light chrome that looks pasted on.
struct AuthField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var identifier: String
    var onSubmit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .insetGlass(cornerRadius: 9, focused: isFocused)
        .animation(Theme.Motion.quick, value: isFocused)
        .focused($isFocused)
        .onSubmit(onSubmit)
        .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
        .accessibilityIdentifier(identifier)
    }
}

/// Five states, rendered as five different things. `Updating…` is not
/// `Connecting…`: conflating them makes the banner claim the app is offline
/// during first sync, which is exactly when it is not.
struct ConnectionBanner: View {
    let state: TDConnectionState

    var body: some View {
        if let text = state.bannerText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .accessibilityIdentifier("connection-banner")
        }
    }
}
