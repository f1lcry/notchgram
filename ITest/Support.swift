import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output

func note(_ message: String) {
    print("[itest] \(message)")
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("itest: " + message + "\n").utf8))
    exit(1)
}

// MARK: - Test-DC identity

/// Reserved test-DC numbers are `99966XYYYY`, where X ∈ 1…3 is the data-centre
/// id and YYYY is arbitrary. The verification code is X repeated as many times
/// as the code length says — and the length is read from the `waitCode` payload,
/// never assumed.
struct TestAccount: Sendable {
    let dcId: Int
    let phoneNumber: String

    /// A fresh YYYY on every construction. The flood limit is roughly five
    /// logins per day per number, so reusing one across runs would start
    /// failing by mid-afternoon.
    init(dcId: Int) {
        self.dcId = dcId
        self.phoneNumber = "99966\(dcId)" + String(format: "%04d", Int.random(in: 0...9999))
    }

    func code(length: Int) -> String {
        String(repeating: String(dcId), count: max(length, 1))
    }
}

/// Which test data centre to try first, and in what order to fall back.
///
/// Not all three are reachable from every network: from the founder's network
/// **DC 3 times out** (`Timeout expired … to DcId{3}`, `No route to host` over
/// IPv6) while DC 1 and DC 2 answer in about a second. Rather than hardcode one
/// network's blocklist, the harness remembers the last DC that worked and tries
/// it first — self-healing, and correct from any network.
enum DataCentrePreference {
    static var file: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".artifacts/itest/preferred-dc")
    }

    static func order() -> [Int] {
        let all = [1, 2, 3]
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let preferred = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              all.contains(preferred)
        else { return all }
        return [preferred] + all.filter { $0 != preferred }
    }

    static func remember(_ dcId: Int) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(dcId)\n".write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Which verification-code length the test DC actually accepted last time.
/// Same self-healing idea as `DataCentrePreference`: measure, do not assume.
enum CodeLengthPreference {
    static var file: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".artifacts/itest/code-length")
    }

    static func load() -> Int? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...8).contains(value)
        else { return nil }
        return value
    }

    static func remember(_ length: Int) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(length)\n".write(to: file, atomically: true, encoding: .utf8)
    }
}

// MARK: - Test media

/// Writes a small deterministic-shape PNG. Deliberately under 1 MB and well
/// inside TDLib's photo limits (≤ 10 MB, width + height ≤ 10000, ratio ≤ 20).
/// CoreGraphics + ImageIO rather than AppKit so nothing here needs a GUI session.
@discardableResult
func writeTestPNG(to url: URL, side: Int = 96) throws -> (width: Int, height: Int) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }

    context.setFillColor(CGColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    // A few blocks so the encoded file is not a single flat run — a degenerate
    // PNG is exactly the kind of thing a server might handle differently.
    let step = max(side / 8, 1)
    for row in 0..<8 where row % 2 == 0 {
        for column in 0..<8 where column % 2 == 0 {
            context.setFillColor(CGColor(
                red: Double(row) / 8, green: 0.5, blue: Double(column) / 8, alpha: 1))
            context.fill(CGRect(x: column * step, y: row * step, width: step, height: step))
        }
    }

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return (side, side)
}

// MARK: - Report

struct StepResult: Codable, Sendable {
    var name: String
    var ok: Bool
    var seconds: Double
    var detail: String?
}

/// One verification section. `skipped` is a first-class outcome, not a
/// disguised failure: a gate that can never go green is a gate everyone learns
/// to ignore, so the reason travels with it.
struct SectionResult: Codable, Sendable {
    enum Status: String, Codable, Sendable { case passed, failed, skipped }

    var status: Status
    var detail: String?
    var reason: String?
    var reference: String?
    var dataCentre: Int?
    var steps: [StepResult]?
}

struct ITestReport: Codable, Sendable {
    var ok: Bool
    var tdlibVersion: String?
    var totalSeconds: Double
    /// liveAuthProbe · liveRoundTrip · updateReplay
    var sections: [String: SectionResult]
    /// Present so a reader knows the run touched no real account.
    var usedTestDc = true

    func write(to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// Why the full live round trip cannot run. Stated once, referenced everywhere.
enum TestDCStatus {
    static let brokenReason = """
        Telegram's test-DC simplified login is broken server-side: the documented         code (the DC digit repeated, with the length taken from         authenticationCodeTypeSms.length) is rejected with PHONE_CODE_INVALID.         Reproduced here against DC 1 and DC 2 with 5-, 6- and 4-digit variants,         confirmed in TDLib's own request log. Not specific to NotchGram — the same         failure is reported for tg_cli with the sample api_id.
        """
    static let reference = "https://github.com/tdlib/td/issues/3083"
}
