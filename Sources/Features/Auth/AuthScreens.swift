import AppKit
import SwiftUI

// MARK: - Phone

struct PhoneEntryScreen: View {
    let session: TelegramSession
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var phoneNumber = ""

    private var isValid: Bool {
        phoneNumber.filter(\.isNumber).count >= 5
    }

    var body: some View {
        AuthScaffold(
            title: "Sign in to Telegram",
            subtitle: "Enter the phone number this account uses, with its country code.",
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: "+7 900 000 00 00",
                    text: $phoneNumber,
                    identifier: "auth-phone",
                    onSubmit: submit,
                    onFocusChange: onFocusChange)
            },
            actions: {
                AuthPrimaryButton(
                    title: "Next", isEnabled: isValid && !session.isBusy, action: submit)
            })
    }

    private func submit() {
        guard isValid, !session.isBusy else { return }
        // TDLib accepts the number with or without punctuation; stripping it
        // here means a pasted "+7 (900) 000-00-00" works.
        let digits = "+" + phoneNumber.filter(\.isNumber)
        Task { await session.submitPhoneNumber(digits) }
    }
}

// MARK: - Code

struct CodeEntryScreen: View {
    let session: TelegramSession
    let challenge: CodeChallenge
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var code = ""

    /// Never hardcode 5. Seven of `AuthenticationCodeType`'s ten cases carry a
    /// length and three carry none at all — for those the input is a word, a
    /// phrase or an auto-filled number, not an N-digit field.
    private var expectedLength: Int? { challenge.kind.expectedLength }

    private var isValid: Bool {
        switch challenge.kind {
        case .digits(let length, _): code.filter(\.isNumber).count == length
        case .word, .phrase: !code.trimmingCharacters(in: .whitespaces).isEmpty
        case .flashCall: code.filter(\.isNumber).count >= 4
        }
    }

    private var subtitle: String {
        switch challenge.kind {
        case .digits(let length, let delivery):
            var text = "A \(length)-digit code was \(delivery.humanDescription)"
            if let prefix = challenge.missedCallPrefix {
                text += " from a number starting \(prefix)"
            }
            return text + " to \(challenge.phoneNumber)."
        case .word(let firstLetter):
            return "Enter the word from the SMS. It starts with “\(firstLetter)”."
        case .phrase(let firstWord):
            return "Enter the phrase from the SMS. It starts with “\(firstWord)”."
        case .flashCall(let pattern):
            return "Enter the last digits of the calling number (\(pattern))."
        }
    }

    var body: some View {
        AuthScaffold(
            title: "Enter the code",
            subtitle: subtitle,
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: expectedLength.map { String(repeating: "•", count: $0) } ?? "code",
                    text: $code,
                    identifier: "auth-code",
                    onSubmit: submit,
                    onFocusChange: onFocusChange)
                    .onChange(of: code) { _, _ in autoSubmitIfComplete() }

                if let url = challenge.fragmentURL {
                    Button("Open Fragment") { NSWorkspace.shared.open(URL(string: url)!) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.accent)
                }
            },
            actions: {
                AuthPrimaryButton(
                    title: "Sign in", isEnabled: isValid && !session.isBusy, action: submit)
                if challenge.canResend {
                    AuthSecondaryButton(title: "Resend", isEnabled: !session.isBusy) {
                        Task { await session.resendCode() }
                    }
                }
            })
    }

    /// A code of exactly the announced length is submitted without a click — the
    /// same thing every Telegram client does, and the difference between a
    /// two-second step and a fiddly one.
    private func autoSubmitIfComplete() {
        guard case .digits(let length, _) = challenge.kind,
              code.filter(\.isNumber).count == length
        else { return }
        submit()
    }

    private func submit() {
        guard isValid, !session.isBusy else { return }
        Task { await session.submitCode(code.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - Password (2FA)

struct PasswordScreen: View {
    let session: TelegramSession
    let challenge: PasswordChallenge
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var password = ""

    private var subtitle: String {
        var text = "This account has two-step verification."
        if !challenge.hint.isEmpty { text += " Hint: \(challenge.hint)" }
        return text
    }

    var body: some View {
        AuthScaffold(
            title: "Enter your password",
            subtitle: subtitle,
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: "Password",
                    text: $password,
                    isSecure: true,
                    identifier: "auth-password",
                    onSubmit: submit,
                    onFocusChange: onFocusChange)

                if challenge.hasRecoveryEmailAddress {
                    Text("Recovery email: \(challenge.recoveryEmailAddressPattern)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            },
            actions: {
                AuthPrimaryButton(
                    title: "Sign in",
                    isEnabled: !password.isEmpty && !session.isBusy,
                    action: submit)
            })
    }

    private func submit() {
        guard !password.isEmpty, !session.isBusy else { return }
        Task { await session.submitPassword(password) }
    }
}

// MARK: - Registration

struct RegistrationScreen: View {
    let session: TelegramSession
    let challenge: RegistrationChallenge
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var firstName = ""
    @State private var lastName = ""

    var body: some View {
        AuthScaffold(
            title: "Create your account",
            subtitle: challenge.termsText.isEmpty
                ? "This number is not registered with Telegram yet."
                : challenge.termsText,
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: "First name", text: $firstName,
                    identifier: "auth-first-name", onFocusChange: onFocusChange)
                AuthField(
                    placeholder: "Last name (optional)", text: $lastName,
                    identifier: "auth-last-name", onSubmit: submit, onFocusChange: onFocusChange)
                if challenge.minUserAge > 0 {
                    Text("You must be at least \(challenge.minUserAge) to use Telegram.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            },
            actions: {
                AuthPrimaryButton(
                    title: "Create account",
                    isEnabled: !firstName.trimmingCharacters(in: .whitespaces).isEmpty
                        && !session.isBusy,
                    action: submit)
            })
    }

    private func submit() {
        let first = firstName.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !session.isBusy else { return }
        Task {
            await session.submitRegistration(
                firstName: first,
                lastName: lastName.trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: - Email

struct EmailAddressScreen: View {
    let session: TelegramSession
    let allowAppleId: Bool
    let allowGoogleId: Bool
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var email = ""

    var body: some View {
        AuthScaffold(
            title: "Confirm your email",
            subtitle: "Telegram needs the login email for this account."
                + (allowAppleId || allowGoogleId
                    ? " Apple/Google sign-in is offered on other clients but not here."
                    : ""),
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: "you@example.com", text: $email,
                    identifier: "auth-email", onSubmit: submit, onFocusChange: onFocusChange)
            },
            actions: {
                AuthPrimaryButton(
                    title: "Continue",
                    isEnabled: email.contains("@") && !session.isBusy,
                    action: submit)
            })
    }

    private func submit() {
        guard email.contains("@"), !session.isBusy else { return }
        Task { await session.submitEmailAddress(email.trimmingCharacters(in: .whitespaces)) }
    }
}

struct EmailCodeScreen: View {
    let session: TelegramSession
    let challenge: EmailCodeChallenge
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var code = ""

    var body: some View {
        AuthScaffold(
            title: "Enter the email code",
            // `length` may be 0 meaning "unknown" on the email path, so the
            // field must accept any length rather than block on a count.
            subtitle: "Sent to \(challenge.emailAddressPattern).",
            error: session.lastError,
            isBusy: session.isBusy,
            fields: {
                AuthField(
                    placeholder: "code", text: $code,
                    identifier: "auth-email-code", onSubmit: submit, onFocusChange: onFocusChange)
                if challenge.canReset {
                    Text("This email can be reset from another signed-in device.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            },
            actions: {
                AuthPrimaryButton(
                    title: "Confirm",
                    isEnabled: !code.isEmpty && !session.isBusy,
                    action: submit)
            })
    }

    private func submit() {
        guard !code.isEmpty, !session.isBusy else { return }
        Task { await session.submitEmailCode(code.trimmingCharacters(in: .whitespaces)) }
    }
}

// MARK: - States with no input

struct OtherDeviceScreen: View {
    let link: String

    var body: some View {
        AuthScaffold(
            title: "Confirm on another device",
            subtitle: "Telegram is waiting for this login to be approved elsewhere.",
            fields: {
                Text(link)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityIdentifier("auth-other-device-link")
            },
            actions: {
                AuthSecondaryButton(title: "Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
            })
    }
}

struct PremiumPurchaseScreen: View {
    let challenge: PremiumPurchaseChallenge

    var body: some View {
        AuthScaffold(
            title: "Telegram Premium required",
            subtitle: "This number can only sign in with a Premium subscription "
                + "(\(challenge.premiumDayCount) days, product \(challenge.storeProductId)). "
                + "NotchGram cannot complete that purchase — use the official app, then come back.",
            fields: {
                if !challenge.supportEmailAddress.isEmpty {
                    Text("Support: \(challenge.supportEmailAddress)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .textSelection(.enabled)
                }
            },
            actions: { EmptyView() })
    }
}

struct AuthProgressScreen: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("auth-progress")
    }
}

/// The leaf that keeps a surprise from becoming a hang.
///
/// If a future TDLib adds an authorization state this build does not model, the
/// panel shows what it is and offers the raw value for a bug report — instead of
/// a blank rectangle at the one moment there is no second chance.
struct UnsupportedStateScreen: View {
    let rawState: String

    var body: some View {
        AuthScaffold(
            title: "Unsupported login step",
            subtitle: "Telegram asked for a step this version of NotchGram does not know how to "
                + "show. Sign in with the official app once, then reopen NotchGram.",
            fields: {
                Text(rawState)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("auth-unsupported-raw")
            },
            actions: {
                AuthSecondaryButton(title: "Copy diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        "NotchGram unsupported authorization state: \(rawState)", forType: .string)
                }
            })
    }
}
