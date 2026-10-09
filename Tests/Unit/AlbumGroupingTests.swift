import XCTest

@testable import NotchGram

/// `ConversationView.units(from:)` — the collapse of `media_album_id` runs
/// into single mosaic posts (C4), and the mosaic's layout arithmetic.
@MainActor
final class AlbumGroupingTests: XCTestCase {

    private func item(
        _ id: Int64, album: Int64 = 0, photo: Bool = true, outgoing: Bool = false
    ) -> MessageItem {
        MessageItem(
            UpdateFixtures.message(
                id: UpdateFixtures.serverMessageId(id),
                chatId: 1, senderUserId: 7,
                content: photo
                    ? UpdateFixtures.photo(sizes: [UpdateFixtures.photoSize(fileId: Int(id))])
                    : UpdateFixtures.text("t\(id)"),
                isOutgoing: outgoing,
                date: Int(id) * 10,
                mediaAlbumId: album))
    }

    func testConsecutiveAlbumMessagesCollapseIntoOneUnit() {
        let units = ConversationView.units(from: [
            item(1), item(2, album: 9), item(3, album: 9), item(4, album: 9), item(5),
        ])
        XCTAssertEqual(units.count, 3)
        guard case .album(let run) = units[1] else {
            return XCTFail("middle unit must be the album")
        }
        XCTAssertEqual(run.map(\.messageId), [2, 3, 4].map(UpdateFixtures.serverMessageId))
    }

    func testDifferentAlbumsStaySeparate() {
        let units = ConversationView.units(from: [
            item(1, album: 9), item(2, album: 9), item(3, album: 11), item(4, album: 11),
        ])
        XCTAssertEqual(units.count, 2)
    }

    /// A lone message that happens to carry an album id (its siblings not
    /// loaded yet) renders as an ordinary bubble, not a one-cell mosaic.
    func testSingleAlbumMessageStaysSingle() {
        let units = ConversationView.units(from: [item(1, album: 9), item(2)])
        XCTAssertEqual(units.count, 2)
        for unit in units {
            if case .album = unit { XCTFail("no album unit expected") }
        }
    }

    /// Text messages never join a mosaic even with an album id.
    func testNonMediaContentIsNotGrouped() {
        let units = ConversationView.units(from: [
            item(1, album: 9, photo: false), item(2, album: 9, photo: false),
        ])
        XCTAssertEqual(units.count, 2)
    }

    // MARK: - Mosaic arithmetic

    func testMosaicRowsFillTheAlbumWidthExactly() {
        let items = (1...5).map { item(Int64($0), album: 9) }
        let width: CGFloat = 300
        let layout = AlbumMosaic.layout(for: items, width: width)
        XCTAssertEqual(layout.map(\.count), [2, 3])
        for row in layout {
            let spacing = CGFloat(row.count - 1) * 2
            let total = row.reduce(CGFloat(0)) { $0 + $1.size.width } + spacing
            XCTAssertEqual(total, width, accuracy: 0.5)
            for cell in row {
                XCTAssertGreaterThanOrEqual(cell.size.height, 72)
                XCTAssertLessThanOrEqual(cell.size.height, 240)
            }
        }
    }

    func testRowPatternsCoverAllCounts() {
        for count in 2...12 {
            XCTAssertEqual(
                AlbumMosaic.rowPattern(count).reduce(0, +) >= min(count, 10), true,
                "pattern for \(count) items must place at least \(min(count, 10)) cells")
        }
    }
}
