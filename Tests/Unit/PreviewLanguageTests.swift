import XCTest
@testable import NotchGram

/// The UI language policy of the public build: an explicit choice wins,
/// otherwise the Mac's first preferred language decides — Russian for Russian,
/// English for everything else.
final class PreviewLanguageTests: XCTestCase {

    func testExplicitChoiceWinsOverTheSystem() {
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: "en", preferredLanguages: ["ru-RU"]), .en)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: "ru", preferredLanguages: ["en-US"]), .ru)
    }

    func testNoChoiceFollowsTheFirstPreferredLanguage() {
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: nil, preferredLanguages: ["ru-RU", "en-US"]), .ru)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: nil, preferredLanguages: ["ru"]), .ru)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: nil, preferredLanguages: ["en-US", "ru-RU"]), .en)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: nil, preferredLanguages: ["de-DE"]), .en)
    }

    /// The old default was Russian for everyone; a stranger's Mac with no
    /// preference at all must now get English.
    func testNoPreferenceAtAllIsEnglish() {
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: nil, preferredLanguages: []), .en)
    }

    /// "system" was a valid explicit value before; it keeps meaning "follow
    /// the Mac", as does anything unrecognised.
    func testLegacySystemValueFollowsTheMac() {
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: "system", preferredLanguages: ["ru-RU"]), .ru)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: "system", preferredLanguages: ["fr-FR"]), .en)
        XCTAssertEqual(PreviewLanguage.resolve(appLanguage: "xx", preferredLanguages: ["en-GB"]), .en)
    }
}
