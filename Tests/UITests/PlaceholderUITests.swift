import XCTest

// XCUITest is deliberately secondary to DebugBridge (see the session brief's
// fallback playbook); this target exists so the scheme is complete.
final class PlaceholderUITests: XCTestCase {
    func testHarnessRuns() { XCTAssertTrue(true) }
}
