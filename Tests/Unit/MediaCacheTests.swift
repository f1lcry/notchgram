import AppKit
import XCTest

@testable import NotchGram

/// Regression tests for the avatar-bleed bug: `MinithumbCache` keyed on
/// `count + prefix(16).hashValue`, and every TDLib minithumbnail is a JPEG from
/// the same encoder — identical first 16 bytes — so any two payloads of equal
/// byte length collided and the first-cached avatar showed for both chats.
final class MediaCacheTests: XCTestCase {

    /// A solid-colour PNG, padded past its IEND marker to an exact byte length.
    /// ImageIO ignores trailing bytes, so the payload stays decodable while the
    /// length is forced equal between two different images — the exact shape of
    /// a real minithumbnail collision.
    private func paddedImageData(color: NSColor, length: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        var data = rep.representation(using: .png, properties: [:])!
        precondition(data.count <= length, "raise the target length")
        data.append(Data(repeating: 0, count: length - data.count))
        return data
    }

    @MainActor
    func testEqualLengthPayloadsWithEqualPrefixesDoNotCollide() {
        let red = paddedImageData(color: .red, length: 600)
        let blue = paddedImageData(color: .blue, length: 600)
        XCTAssertEqual(red.count, blue.count)
        XCTAssertEqual(red.prefix(16), blue.prefix(16), "PNG header must be shared for the repro")

        let first = MinithumbCache.image(for: red)
        let second = MinithumbCache.image(for: blue)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        // A key collision returns the first-cached instance for the second
        // payload — identity is the observable.
        XCTAssertTrue(first !== second, "distinct payloads must decode to distinct cached images")
    }

    @MainActor
    func testIdenticalPayloadHitsTheCache() {
        let data = paddedImageData(color: .green, length: 600)
        let first = MinithumbCache.image(for: data)
        let second = MinithumbCache.image(for: data)
        XCTAssertTrue(first === second, "same payload must be served from cache")
    }
}
