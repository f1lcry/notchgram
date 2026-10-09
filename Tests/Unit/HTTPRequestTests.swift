import XCTest
@testable import NotchGram

/// The DebugBridge parser is the one piece of hand-rolled protocol code in the
/// harness path. If it mis-frames a request the whole L3 layer goes dark, so it
/// is unit-tested rather than exercised only through `curl`.
final class HTTPRequestTests: XCTestCase {

    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testParsesSimpleGet() throws {
        let request = try XCTUnwrap(HTTPRequest(data("GET /status HTTP/1.1\r\nHost: x\r\n\r\n")))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/status")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testReturnsNilUntilHeadersAreComplete() {
        XCTAssertNil(HTTPRequest(data("GET /status HTTP/1.1\r\nHost: x")))
        XCTAssertNil(HTTPRequest(data("")))
    }

    func testReturnsNilUntilFullBodyArrived() {
        let partial = "POST /command HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"command\""
        XCTAssertNil(HTTPRequest(data(partial)))
    }

    func testParsesPostWithBody() throws {
        let body = #"{"command":"expand"}"#
        let raw = "POST /command HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let request = try XCTUnwrap(HTTPRequest(data(raw)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/command")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    func testContentLengthHeaderIsCaseInsensitive() throws {
        let body = #"{"command":"collapse"}"#
        let raw = "POST /command HTTP/1.1\r\ncontent-length: \(body.utf8.count)\r\n\r\n" + body
        let request = try XCTUnwrap(HTTPRequest(data(raw)))
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    /// Arguments travel in the JSON body, so a query string must not become part
    /// of the route or every `?x=1` would 404.
    func testStripsQueryString() throws {
        let request = try XCTUnwrap(HTTPRequest(data("GET /status?pretty=1 HTTP/1.1\r\n\r\n")))
        XCTAssertEqual(request.path, "/status")
    }

    /// A trailing byte from a pipelined request must not be swallowed into the
    /// body, or the next command silently corrupts this one.
    func testBodyIsTruncatedToContentLength() throws {
        let raw = "POST /command HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}EXTRA"
        let request = try XCTUnwrap(HTTPRequest(data(raw)))
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{}")
    }

    func testRejectsMalformedRequestLine() {
        XCTAssertNil(HTTPRequest(data("NONSENSE\r\n\r\n")))
    }

    func testDecodesCommandRequestFromParsedBody() throws {
        let body = #"{"command":"setSize","width":900,"height":600}"#
        let raw = "POST /command HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let request = try XCTUnwrap(HTTPRequest(data(raw)))
        let command = try JSONDecoder().decode(DebugCommandRequest.self, from: request.body)
        XCTAssertEqual(command.command, "setSize")
        XCTAssertEqual(command.width, 900)
        XCTAssertEqual(command.height, 600)
        XCTAssertNil(command.chatId)
    }
}
