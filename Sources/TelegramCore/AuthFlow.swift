import Foundation
@preconcurrency import TDLibKit

//
// AuthFlow — TDLib's 13 authorization states, mapped to something the panel can
// render, as a pure function.
//
// "All 13" is not pedantry. A fresh test-DC number *always* lands in
// `waitRegistration`, `waitEmailAddress`/`waitEmailCode` appear on accounts with
// login email, and `waitPremiumPurchase` exists in 1.8.66. A flow that models
// only phone→code→ready hangs on any of them — and CP1 is the founder's single
// interactive login, where a hang costs a checkpoint.
//

/// How the verification code is delivered, and what the input field should be.
///
/// `length` lives on the *payload* of `AuthenticationCodeType`, and three of its
/// ten cases carry no length at all — for those the input is a word, a phrase or
/// an auto-filled number pattern, not an N-digit field. Never hardcode 5.
public enum CodeChallengeKind: Equatable, Hashable, Sendable {
    case digits(length: Int, delivery: CodeDelivery)
    /// `authenticationCodeTypeSmsWord` — the user types a whole word.
    case word(firstLetter: String)
    /// `authenticationCodeTypeSmsPhrase` — the user types a phrase.
    case phrase(firstWord: String)
    /// `authenticationCodeTypeFlashCall` — the code is the caller's number.
    case flashCall(pattern: String)

    public var expectedLength: Int? {
        if case .digits(let length, _) = self { return length }
        return nil
    }
}

public enum CodeDelivery: String, Equatable, Hashable, Sendable, CaseIterable {
    case telegramMessage, sms, call, missedCall, fragment, firebase

    public var humanDescription: String {
        switch self {
        case .telegramMessage: "sent in Telegram"
        case .sms: "sent by SMS"
        case .call: "dictated in a call"
        case .missedCall: "the last digits of the calling number"
        case .fragment: "sent via Fragment"
        case .firebase: "sent by your device"
        }
    }
}

public struct CodeChallenge: Equatable, Hashable, Sendable {
    public var phoneNumber: String
    public var kind: CodeChallengeKind
    /// Seconds before the code may be re-sent.
    public var timeout: Int
    /// Description of the next delivery method, if TDLib offers a resend path.
    public var nextDelivery: CodeDelivery?
    /// `authenticationCodeTypeMissedCall` — digits before the code.
    public var missedCallPrefix: String?
    /// `authenticationCodeTypeFragment` — where to fetch the code.
    public var fragmentURL: String?

    public var canResend: Bool { nextDelivery != nil }
}

public struct PasswordChallenge: Equatable, Hashable, Sendable {
    public var hint: String
    public var hasRecoveryEmailAddress: Bool
    public var recoveryEmailAddressPattern: String
    public var hasPassportData: Bool
}

public struct RegistrationChallenge: Equatable, Hashable, Sendable {
    /// Terms the user must accept; empty when TDLib sent none.
    public var termsText: String
    public var minUserAge: Int
    public var showPopup: Bool
}

public struct EmailCodeChallenge: Equatable, Hashable, Sendable {
    public var emailAddressPattern: String
    /// TDLib may report 0, meaning "unknown" — there is no reliable length on
    /// the email path, so the field must accept any length.
    public var length: Int?
    public var allowAppleId: Bool
    public var allowGoogleId: Bool
    public var canReset: Bool
}

public struct PremiumPurchaseChallenge: Equatable, Hashable, Sendable {
    public var storeProductId: String
    public var premiumDayCount: Int
    public var supportEmailAddress: String
    public var supportEmailSubject: String
}

/// What the panel shows. One case per TDLib state, plus a leaf for anything a
/// future TDLib adds — a surprise state must degrade to a readable screen with
/// copyable diagnostics, never to a hang.
public enum AuthState: Equatable, Hashable, Sendable {
    /// `waitTdlibParameters` — answered automatically; the user sees a spinner.
    case initializing
    case waitPhoneNumber
    case waitCode(CodeChallenge)
    case waitPassword(PasswordChallenge)
    case waitRegistration(RegistrationChallenge)
    case waitEmailAddress(allowAppleId: Bool, allowGoogleId: Bool)
    case waitEmailCode(EmailCodeChallenge)
    case waitOtherDeviceConfirmation(link: String)
    case waitPremiumPurchase(PremiumPurchaseChallenge)
    case ready
    case loggingOut
    case closing
    case closed
    case unsupported(String)

    /// True while the user has to do something. Drives whether the panel pins
    /// itself open.
    public var needsUserInput: Bool {
        switch self {
        case .waitPhoneNumber, .waitCode, .waitPassword, .waitRegistration,
             .waitEmailAddress, .waitEmailCode, .waitOtherDeviceConfirmation,
             .waitPremiumPurchase, .unsupported:
            true
        case .initializing, .ready, .loggingOut, .closing, .closed:
            false
        }
    }

    /// Stable identifier used by DebugBridge's `gotoAuthState` and by the
    /// session report — never a localized string.
    public var name: String {
        switch self {
        case .initializing: "initializing"
        case .waitPhoneNumber: "waitPhoneNumber"
        case .waitCode: "waitCode"
        case .waitPassword: "waitPassword"
        case .waitRegistration: "waitRegistration"
        case .waitEmailAddress: "waitEmailAddress"
        case .waitEmailCode: "waitEmailCode"
        case .waitOtherDeviceConfirmation: "waitOtherDeviceConfirmation"
        case .waitPremiumPurchase: "waitPremiumPurchase"
        case .ready: "ready"
        case .loggingOut: "loggingOut"
        case .closing: "closing"
        case .closed: "closed"
        case .unsupported(let raw): "unsupported(\(raw))"
        }
    }
}

/// Pure mapping from TDLib's model to ours. No I/O, no TDLib calls — this is
/// what makes the whole auth surface unit-testable without a network.
public enum AuthFlow {

    public static func state(from tdState: AuthorizationState) -> AuthState {
        switch tdState {
        case .authorizationStateWaitTdlibParameters:
            return .initializing

        case .authorizationStateWaitPhoneNumber:
            return .waitPhoneNumber

        case .authorizationStateWaitCode(let payload):
            return .waitCode(challenge(from: payload.codeInfo))

        case .authorizationStateWaitPassword(let payload):
            return .waitPassword(PasswordChallenge(
                hint: payload.passwordHint,
                hasRecoveryEmailAddress: payload.hasRecoveryEmailAddress,
                recoveryEmailAddressPattern: payload.recoveryEmailAddressPattern,
                hasPassportData: payload.hasPassportData))

        case .authorizationStateWaitRegistration(let payload):
            let terms = payload.termsOfService
            return .waitRegistration(RegistrationChallenge(
                termsText: terms.text.text,
                minUserAge: terms.minUserAge,
                showPopup: terms.showPopup))

        case .authorizationStateWaitEmailAddress(let payload):
            return .waitEmailAddress(
                allowAppleId: payload.allowAppleId,
                allowGoogleId: payload.allowGoogleId)

        case .authorizationStateWaitEmailCode(let payload):
            let info = payload.codeInfo
            return .waitEmailCode(EmailCodeChallenge(
                emailAddressPattern: info.emailAddressPattern,
                length: info.length > 0 ? info.length : nil,
                allowAppleId: payload.allowAppleId,
                allowGoogleId: payload.allowGoogleId,
                canReset: payload.emailAddressResetState != nil))

        case .authorizationStateWaitOtherDeviceConfirmation(let payload):
            return .waitOtherDeviceConfirmation(link: payload.link)

        case .authorizationStateWaitPremiumPurchase(let payload):
            return .waitPremiumPurchase(PremiumPurchaseChallenge(
                storeProductId: payload.storeProductId,
                premiumDayCount: payload.premiumDayCount,
                supportEmailAddress: payload.supportEmailAddress,
                supportEmailSubject: payload.supportEmailSubject))

        case .authorizationStateReady:
            return .ready

        case .authorizationStateLoggingOut:
            return .loggingOut

        case .authorizationStateClosing:
            return .closing

        case .authorizationStateClosed:
            return .closed
        }
    }

    static func challenge(from info: AuthenticationCodeInfo) -> CodeChallenge {
        var challenge = CodeChallenge(
            phoneNumber: info.phoneNumber,
            kind: kind(of: info.type),
            timeout: info.timeout,
            nextDelivery: info.nextType.flatMap(delivery(of:)))

        if case .authenticationCodeTypeMissedCall(let missed) = info.type {
            challenge.missedCallPrefix = missed.phoneNumberPrefix
        }
        if case .authenticationCodeTypeFragment(let fragment) = info.type {
            challenge.fragmentURL = fragment.url
        }
        return challenge
    }

    static func kind(of type: AuthenticationCodeType) -> CodeChallengeKind {
        switch type {
        case .authenticationCodeTypeTelegramMessage(let value):
            .digits(length: value.length, delivery: .telegramMessage)
        case .authenticationCodeTypeSms(let value):
            .digits(length: value.length, delivery: .sms)
        case .authenticationCodeTypeCall(let value):
            .digits(length: value.length, delivery: .call)
        case .authenticationCodeTypeMissedCall(let value):
            .digits(length: value.length, delivery: .missedCall)
        case .authenticationCodeTypeFragment(let value):
            .digits(length: value.length, delivery: .fragment)
        case .authenticationCodeTypeFirebaseAndroid(let value):
            .digits(length: value.length, delivery: .firebase)
        case .authenticationCodeTypeFirebaseIos(let value):
            .digits(length: value.length, delivery: .firebase)
        case .authenticationCodeTypeSmsWord(let value):
            .word(firstLetter: value.firstLetter)
        case .authenticationCodeTypeSmsPhrase(let value):
            .phrase(firstWord: value.firstWord)
        case .authenticationCodeTypeFlashCall(let value):
            .flashCall(pattern: value.pattern)
        }
    }

    static func delivery(of type: AuthenticationCodeType) -> CodeDelivery? {
        switch type {
        case .authenticationCodeTypeTelegramMessage: .telegramMessage
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord,
             .authenticationCodeTypeSmsPhrase: .sms
        case .authenticationCodeTypeCall: .call
        case .authenticationCodeTypeMissedCall, .authenticationCodeTypeFlashCall: .missedCall
        case .authenticationCodeTypeFragment: .fragment
        case .authenticationCodeTypeFirebaseAndroid, .authenticationCodeTypeFirebaseIos: .firebase
        }
    }
}

/// The five connection states, mapped one-to-one. `updating` is not
/// `connecting` — conflating them makes the banner lie during first sync, which
/// is exactly when the user is most likely to think the app is broken.
public enum TDConnectionState: String, Equatable, Hashable, Sendable {
    case waitingForNetwork, connectingToProxy, connecting, updating, ready

    public init(_ state: ConnectionState) {
        switch state {
        case .connectionStateWaitingForNetwork: self = .waitingForNetwork
        case .connectionStateConnectingToProxy: self = .connectingToProxy
        case .connectionStateConnecting: self = .connecting
        case .connectionStateUpdating: self = .updating
        case .connectionStateReady: self = .ready
        }
    }

    public var bannerText: String? {
        switch self {
        case .waitingForNetwork: "Waiting for network…"
        case .connectingToProxy: "Connecting to proxy…"
        case .connecting: "Connecting…"
        case .updating: "Updating…"
        case .ready: nil
        }
    }
}
