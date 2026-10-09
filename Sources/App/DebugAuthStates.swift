// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import Foundation

/// Named authorization states for DebugBridge's `gotoAuthState`.
///
/// The rule from ARCHITECTURE.md is that every UI state a human can reach must
/// be reachable through DebugBridge without a physical hover — and for the auth
/// flow that is the only way to review all thirteen screens, because there is no
/// account on earth that visits `waitPremiumPurchase` and `waitRegistration` and
/// `waitOtherDeviceConfirmation` in one session.
///
/// The payloads are representative rather than minimal: a code screen with a
/// zero-length code or an empty phone number would look fine and prove nothing.
enum DebugAuthStates {
    static let names = [
        "live", "initializing", "waitPhoneNumber", "waitCode", "waitCodeSms", "waitCodeWord",
        "waitCodeMissedCall", "waitPassword", "waitRegistration", "waitEmailAddress",
        "waitEmailCode", "waitOtherDeviceConfirmation", "waitPremiumPurchase", "ready",
        "loggingOut", "closing", "closed", "unsupported",
    ]

    static func state(named name: String) throws -> AuthState {
        switch name {
        case "initializing": .initializing
        case "waitPhoneNumber": .waitPhoneNumber

        case "waitCode":
            .waitCode(CodeChallenge(
                phoneNumber: "+7 900 000 00 00",
                kind: .digits(length: 5, delivery: .telegramMessage),
                timeout: 90,
                nextDelivery: .sms))
        case "waitCodeSms":
            .waitCode(CodeChallenge(
                phoneNumber: "+7 900 000 00 00",
                kind: .digits(length: 6, delivery: .sms),
                timeout: 90,
                nextDelivery: .call))
        // Three of the ten code types carry no length at all; a screen that
        // assumes an N-digit field renders something unusable for them.
        case "waitCodeWord":
            .waitCode(CodeChallenge(
                phoneNumber: "+7 900 000 00 00",
                kind: .word(firstLetter: "T"),
                timeout: 90,
                nextDelivery: nil))
        case "waitCodeMissedCall":
            .waitCode(CodeChallenge(
                phoneNumber: "+7 900 000 00 00",
                kind: .digits(length: 4, delivery: .missedCall),
                timeout: 90,
                nextDelivery: nil,
                missedCallPrefix: "+7 999"))

        case "waitPassword":
            .waitPassword(PasswordChallenge(
                hint: "the usual one",
                hasRecoveryEmailAddress: true,
                recoveryEmailAddressPattern: "f***@o***.com",
                hasPassportData: false))

        case "waitRegistration":
            .waitRegistration(RegistrationChallenge(
                termsText: "By signing up you accept the Telegram Terms of Service.",
                minUserAge: 16,
                showPopup: true))

        case "waitEmailAddress":
            .waitEmailAddress(allowAppleId: true, allowGoogleId: true)

        case "waitEmailCode":
            .waitEmailCode(EmailCodeChallenge(
                emailAddressPattern: "f***@o***.com",
                length: 6,
                allowAppleId: false,
                allowGoogleId: false,
                canReset: true))

        case "waitOtherDeviceConfirmation":
            .waitOtherDeviceConfirmation(link: "tg://login?token=AQABCDEFGHIJKLMNOPQRSTUVWXYZ")

        case "waitPremiumPurchase":
            .waitPremiumPurchase(PremiumPurchaseChallenge(
                storeProductId: "org.telegram.telegramPremium.monthly",
                premiumDayCount: 30,
                supportEmailAddress: "premium@telegram.org",
                supportEmailSubject: "Premium activation"))

        case "ready": .ready
        case "loggingOut": .loggingOut
        case "closing": .closing
        case "closed": .closed
        case "unsupported": .unsupported("authorizationStateWaitSomethingNew")

        default:
            throw DebugRouterError.missingArgument(
                "state must be one of: \(names.joined(separator: ", "))")
        }
    }
}

#endif
