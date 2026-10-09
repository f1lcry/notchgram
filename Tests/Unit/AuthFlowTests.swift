import XCTest
import TDLibKit
@testable import NotchGram

/// `AuthFlow.state(from:)` is a pure function, which is the whole point: the
/// entire authorization surface — including the states nobody can reach on
/// demand (`waitPremiumPurchase`, `waitOtherDeviceConfirmation`) — is verifiable
/// without a network, an account, or a founder.
final class AuthFlowTests: XCTestCase {

    private func codeInfo(
        type: AuthenticationCodeType,
        next: AuthenticationCodeType? = nil,
        timeout: Int = 60
    ) -> AuthenticationCodeInfo {
        AuthenticationCodeInfo(
            nextType: next, phoneNumber: "9996621234", timeout: timeout, type: type)
    }

    // MARK: - Simple states

    func testWaitTdlibParametersIsInitializing() {
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateWaitTdlibParameters), .initializing)
    }

    func testTerminalStates() {
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateReady), .ready)
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateLoggingOut), .loggingOut)
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateClosing), .closing)
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateClosed), .closed)
        XCTAssertEqual(AuthFlow.state(from: .authorizationStateWaitPhoneNumber), .waitPhoneNumber)
    }

    /// Only the wait states pin the panel open. Getting this wrong either
    /// collapses the panel mid-login or pins it forever after.
    func testNeedsUserInputPartitionsTheStates() {
        XCTAssertFalse(AuthState.initializing.needsUserInput)
        XCTAssertFalse(AuthState.ready.needsUserInput)
        XCTAssertFalse(AuthState.loggingOut.needsUserInput)
        XCTAssertFalse(AuthState.closing.needsUserInput)
        XCTAssertFalse(AuthState.closed.needsUserInput)
        XCTAssertTrue(AuthState.waitPhoneNumber.needsUserInput)
        XCTAssertTrue(AuthState.unsupported("whatever").needsUserInput)
    }

    // MARK: - Code challenge

    /// The rule the plan calls out explicitly: read the length from the payload,
    /// never hardcode 5. A 6-digit Telegram-message code must round-trip as 6.
    func testCodeLengthComesFromThePayload() {
        let state = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeTelegramMessage(
                    AuthenticationCodeTypeTelegramMessage(length: 6)))))

        guard case .waitCode(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(challenge.kind, .digits(length: 6, delivery: .telegramMessage))
        XCTAssertEqual(challenge.kind.expectedLength, 6)
        XCTAssertEqual(challenge.phoneNumber, "9996621234")
        XCTAssertEqual(challenge.timeout, 60)
    }

    func testSmsCodeMapsToSmsDelivery() {
        let state = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeSms(AuthenticationCodeTypeSms(length: 5)))))

        guard case .waitCode(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(challenge.kind, .digits(length: 5, delivery: .sms))
    }

    /// Three of the ten code types carry no length at all. A UI that assumes an
    /// N-digit field renders an unusable screen for them.
    func testNonNumericCodeTypesHaveNoLength() {
        let word = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeSmsWord(
                    AuthenticationCodeTypeSmsWord(firstLetter: "T")))))
        guard case .waitCode(let wordChallenge) = AuthFlow.state(from: word) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(wordChallenge.kind, .word(firstLetter: "T"))
        XCTAssertNil(wordChallenge.kind.expectedLength)

        let phrase = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeSmsPhrase(
                    AuthenticationCodeTypeSmsPhrase(firstWord: "apple")))))
        guard case .waitCode(let phraseChallenge) = AuthFlow.state(from: phrase) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(phraseChallenge.kind, .phrase(firstWord: "apple"))

        let flash = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeFlashCall(
                    AuthenticationCodeTypeFlashCall(pattern: "+7*")))))
        guard case .waitCode(let flashChallenge) = AuthFlow.state(from: flash) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(flashChallenge.kind, .flashCall(pattern: "+7*"))
    }

    /// `MissedCall.length` excludes `phoneNumberPrefix`, so the prefix has to
    /// survive the mapping or the user is asked for digits they cannot see.
    func testMissedCallCarriesItsPrefix() {
        let state = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeMissedCall(
                    AuthenticationCodeTypeMissedCall(length: 4, phoneNumberPrefix: "+7999")))))

        guard case .waitCode(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(challenge.kind, .digits(length: 4, delivery: .missedCall))
        XCTAssertEqual(challenge.missedCallPrefix, "+7999")
    }

    func testFragmentCarriesItsURL() {
        let state = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeFragment(
                    AuthenticationCodeTypeFragment(length: 8, url: "https://fragment.com/x")))))

        guard case .waitCode(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertEqual(challenge.fragmentURL, "https://fragment.com/x")
    }

    func testResendIsOfferedOnlyWhenTDLibNamesANextType() {
        let without = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeSms(AuthenticationCodeTypeSms(length: 5)))))
        guard case .waitCode(let noResend) = AuthFlow.state(from: without) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertFalse(noResend.canResend)
        XCTAssertNil(noResend.nextDelivery)

        let with = AuthorizationState.authorizationStateWaitCode(
            AuthorizationStateWaitCode(codeInfo: codeInfo(
                type: .authenticationCodeTypeSms(AuthenticationCodeTypeSms(length: 5)),
                next: .authenticationCodeTypeCall(AuthenticationCodeTypeCall(length: 5)))))
        guard case .waitCode(let resend) = AuthFlow.state(from: with) else {
            return XCTFail("expected waitCode")
        }
        XCTAssertTrue(resend.canResend)
        XCTAssertEqual(resend.nextDelivery, .call)
    }

    // MARK: - Other wait states

    func testWaitPassword() {
        let state = AuthorizationState.authorizationStateWaitPassword(
            AuthorizationStateWaitPassword(
                hasPassportData: false,
                hasRecoveryEmailAddress: true,
                passwordHint: "the usual",
                recoveryEmailAddressPattern: "f***@o***.com"))

        guard case .waitPassword(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitPassword")
        }
        XCTAssertEqual(challenge.hint, "the usual")
        XCTAssertTrue(challenge.hasRecoveryEmailAddress)
        XCTAssertEqual(challenge.recoveryEmailAddressPattern, "f***@o***.com")
    }

    /// A fresh test-DC number *always* lands here, so this is not an exotic
    /// branch — it is the normal path for every automated run.
    func testWaitRegistrationCarriesTerms() {
        let terms = TermsOfService(
            minUserAge: 16,
            showPopup: true,
            text: FormattedText(entities: [], text: "Be nice."))
        let state = AuthorizationState.authorizationStateWaitRegistration(
            AuthorizationStateWaitRegistration(termsOfService: terms))

        guard case .waitRegistration(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitRegistration")
        }
        XCTAssertEqual(challenge.termsText, "Be nice.")
        XCTAssertEqual(challenge.minUserAge, 16)
        XCTAssertTrue(challenge.showPopup)
    }

    func testWaitOtherDeviceConfirmation() {
        let state = AuthorizationState.authorizationStateWaitOtherDeviceConfirmation(
            AuthorizationStateWaitOtherDeviceConfirmation(link: "tg://login?token=x"))
        XCTAssertEqual(
            AuthFlow.state(from: state),
            .waitOtherDeviceConfirmation(link: "tg://login?token=x"))
    }

    func testWaitPremiumPurchase() {
        let state = AuthorizationState.authorizationStateWaitPremiumPurchase(
            AuthorizationStateWaitPremiumPurchase(
                premiumDayCount: 30,
                storeProductId: "premium.month",
                supportEmailAddress: "support@telegram.org",
                supportEmailSubject: "Premium"))

        guard case .waitPremiumPurchase(let challenge) = AuthFlow.state(from: state) else {
            return XCTFail("expected waitPremiumPurchase")
        }
        XCTAssertEqual(challenge.storeProductId, "premium.month")
        XCTAssertEqual(challenge.premiumDayCount, 30)
    }

    // MARK: - Connection state

    /// `updating` is not `connecting`. Collapsing them makes the banner claim
    /// the app is offline during first sync, which is exactly when it is not.
    func testConnectionStatesMapOneToOne() {
        XCTAssertEqual(TDConnectionState(.connectionStateWaitingForNetwork), .waitingForNetwork)
        XCTAssertEqual(TDConnectionState(.connectionStateConnectingToProxy), .connectingToProxy)
        XCTAssertEqual(TDConnectionState(.connectionStateConnecting), .connecting)
        XCTAssertEqual(TDConnectionState(.connectionStateUpdating), .updating)
        XCTAssertEqual(TDConnectionState(.connectionStateReady), .ready)

        XCTAssertNil(TDConnectionState.ready.bannerText)
        XCTAssertNotNil(TDConnectionState.updating.bannerText)
        XCTAssertNotEqual(TDConnectionState.updating.bannerText,
                          TDConnectionState.connecting.bannerText)
    }
}
