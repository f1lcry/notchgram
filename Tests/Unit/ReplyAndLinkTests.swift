import SwiftUI
import XCTest
@preconcurrency import TDLibKit

@testable import NotchGram

/// Reply quotes and in-text links — both resolved from live TDLib shapes:
/// entity offsets in UTF-16 units, reply targets by message id.
@MainActor
final class ReplyAndLinkTests: XCTestCase {

    private func item(_ message: Message, name: String = "") -> MessageItem {
        MessageItem(message, senderName: name)
    }

    // MARK: - Links

    func testBareURLEntityBecomesALink() throws {
        let url = "https://example.org/a"
        let text = "see \(url) now"
        let entity = try XCTUnwrap(UpdateFixtures.urlEntity(url, in: text))
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1), chatId: 1, senderUserId: 2,
            content: UpdateFixtures.text(text, entities: [entity]))

        let links = item(message).textLinks
        XCTAssertEqual(links, [TextLink(offset: 4, length: url.utf16.count, url: url)])

        let attributed = MessageBubbleView.linkified(text, links: links)
        let linked = attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0) }
        }
        XCTAssertEqual(linked.count, 1)
        XCTAssertEqual(linked.first?.0, url)
        XCTAssertEqual(linked.first?.1, URL(string: url))
    }

    /// An emoji before the link is two UTF-16 units: counting characters
    /// instead would shift the link by one and swallow a neighbour.
    func testOffsetsAreUTF16AfterAnEmoji() throws {
        let url = "example.org"
        let text = "🏕 \(url)"
        let entity = try XCTUnwrap(UpdateFixtures.urlEntity(url, in: text))
        XCTAssertEqual(entity.offset, 3)
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1), chatId: 1, senderUserId: 2,
            content: UpdateFixtures.text(text, entities: [entity]))
        let links = item(message).textLinks
        // A bare domain gets a scheme.
        XCTAssertEqual(links.first?.url, "https://example.org")

        let attributed = MessageBubbleView.linkified(text, links: links)
        let linkedText = attributed.runs.filter { $0.link != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(linkedText, [url])
    }

    func testNamedLinkAndOutOfRangeEntity() {
        let text = "docs here"
        let message = UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(1), chatId: 1, senderUserId: 2,
            content: UpdateFixtures.text(text, entities: [
                TextEntity(length: 4, offset: 0, type: .textEntityTypeTextUrl(
                    TextEntityTypeTextUrl(url: "https://example.org/docs"))),
                TextEntity(length: 50, offset: 5, type: .textEntityTypeUrl),
            ]))
        XCTAssertEqual(
            item(message).textLinks,
            [TextLink(offset: 0, length: 4, url: "https://example.org/docs")])
    }

    // MARK: - Replies

    func testReplyQuoteResolvesWithinTheWindow() {
        let original = item(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(10), chatId: 1, senderUserId: 7,
            content: UpdateFixtures.text("first line\nsecond")), name: "Maya Chen")
        let mine = item(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(11), chatId: 1, senderUserId: 0,
            content: UpdateFixtures.text("hi"), isOutgoing: true))
        let reply = item(UpdateFixtures.message(
            id: UpdateFixtures.serverMessageId(12), chatId: 1, senderUserId: 7,
            content: UpdateFixtures.text("ok"),
            replyToMessageId: UpdateFixtures.serverMessageId(10)))
        XCTAssertEqual(reply.replyToMessageId, UpdateFixtures.serverMessageId(10))

        var index: [Int64: MessageItem]?
        let items = [original, mine, reply]
        let quote = ConversationView.replyQuote(
            for: UpdateFixtures.serverMessageId(10), in: items, indexed: &index)
        XCTAssertEqual(quote?.senderName, "Maya Chen")
        XCTAssertEqual(quote?.text, "first line second")
        XCTAssertEqual(quote?.isOutgoing, false)

        let own = ConversationView.replyQuote(
            for: UpdateFixtures.serverMessageId(11), in: items, indexed: &index)
        XCTAssertEqual(own?.isOutgoing, true)

        // Not loaded: no quote rather than a placeholder.
        XCTAssertNil(ConversationView.replyQuote(
            for: UpdateFixtures.serverMessageId(99), in: items, indexed: &index))
    }
}
