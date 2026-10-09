import XCTest
import TDLibKit
@testable import NotchGram

final class TDErrorTests: XCTestCase {

    /// The harness regenerates its test-DC number instead of sleeping when the
    /// wait is long, so parsing this correctly is what keeps `make itest`
    /// finishing in ~90 s rather than blocking for minutes.
    func testFloodWaitParsing() {
        XCTAssertEqual(TDError(code: 429, message: "FLOOD_WAIT_42").floodWaitSeconds, 42)
        XCTAssertTrue(TDError(code: 429, message: "FLOOD_WAIT_42").isFloodWait)
        XCTAssertNil(TDError(code: 400, message: "PHONE_NUMBER_INVALID").floodWaitSeconds)
        XCTAssertFalse(TDError(code: 400, message: "PHONE_NUMBER_INVALID").isFloodWait)
        // Not a number after the prefix — must not crash or half-match.
        XCTAssertNil(TDError(code: 429, message: "FLOOD_WAIT_").floodWaitSeconds)
        XCTAssertNil(TDError(code: 429, message: "FLOOD_WAIT_soon").floodWaitSeconds)
    }

    /// TDLib is explicit: "If the error code is 406, the error message must not
    /// be processed in any way and must not be displayed to the user."
    func test406IsNeverShownToTheUser() {
        let silent = TDError(code: 406, message: "SOME_INTERNAL_THING")
        XCTAssertTrue(silent.isSilent)
        XCTAssertNil(silent.userFacingMessage)
    }

    func testUnauthorizedIsRecognised() {
        XCTAssertTrue(TDError(code: 401, message: "Unauthorized").isUnauthorized)
        XCTAssertFalse(TDError(code: 400, message: "Bad Request").isUnauthorized)
    }

    func testWrapsTDLibKitError() {
        let wrapped = TDError.wrap(TDLibKit.Error(code: 400, message: "PHONE_CODE_INVALID"))
        XCTAssertEqual(wrapped.code, 400)
        XCTAssertEqual(wrapped.message, "PHONE_CODE_INVALID")
        XCTAssertEqual(wrapped.userFacingMessage, "That code is not correct.")
    }

    /// Non-TDLib failures (cancellation, decoding) must not be mistaken for a
    /// TDLib response code.
    func testWrapsForeignErrorsUnderCodeZero() {
        struct Boom: Swift.Error {}
        let wrapped = TDError.wrap(Boom())
        XCTAssertEqual(wrapped.code, 0)
        XCTAssertFalse(wrapped.isUnauthorized)
        XCTAssertFalse(wrapped.isSilent)
    }

    func testWrapIsIdempotent() {
        let original = TDError(code: 429, message: "FLOOD_WAIT_7")
        XCTAssertEqual(TDError.wrap(original), original)
    }

    func testFloodWaitBeatsTheRawMessageInTheUI() {
        XCTAssertEqual(
            TDError(code: 429, message: "FLOOD_WAIT_7").userFacingMessage,
            "Too many attempts. Try again in 7 s.")
    }
}
