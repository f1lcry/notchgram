import XCTest
@testable import NotchGram

/// Every display topology, as a fixture.
///
/// The point of the `ScreenInfo` seam is that clamshell, hot-unplug, a mirrored
/// pair and a 600-point-wide vertical panel are all just values here — the ones
/// that cannot be produced on demand are exactly the ones most likely to be
/// wrong.
@MainActor
final class NotchGeometryEngineTests: XCTestCase {

    private func geometries(
        _ screens: [ScreenInfo],
        _ settings: GeometrySettings = GeometrySettings()
    ) -> [NotchGeometry] {
        NotchGeometryEngine.geometries(for: screens, settings: settings)
    }

    // MARK: - Detection

    func testNotchedBuiltInIsDetectedAsPhysical() {
        let result = geometries([ScreenFixtures.notchedBuiltIn])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].style, .physical)
        // Measured on this machine: cut-out x 771…956 (w 185) × y 1085…1117.
        XCTAssertEqual(result[0].notch.width, 185)
        XCTAssertEqual(result[0].notch.height, 32)
        XCTAssertEqual(result[0].notch.midX, 864)
    }

    func testExternalDisplaysGetASyntheticTab() {
        let result = geometries([ScreenFixtures.landscapeExternal])
        XCTAssertEqual(result[0].style, .synthetic)
    }

    /// `safeAreaInsets.top` tracks menu-bar *visibility*, not hardware. A
    /// notched display with the menu bar auto-hidden reports 0, and treating
    /// that as "no notch" draws a synthetic tab on top of a real cut-out.
    /// The auxiliary areas are the existence test; the height is what goes to 0.
    func testAuxiliaryAreasAreTheExistenceTestNotSafeArea() {
        let screen = ScreenFixtures.notchedWithHiddenMenuBar
        XCTAssertNotNil(screen.auxiliaryTopLeft)
        // With safeAreaTop == 0 there is no usable cut-out rect, so this screen
        // correctly falls back to a drawn tab rather than a zero-height one.
        XCTAssertNil(screen.physicalNotch)
        XCTAssertEqual(geometries([screen])[0].style, .synthetic)
        XCTAssertGreaterThan(geometries([screen])[0].notch.height, 0)
    }

    /// Clamshell: the built-in is absent from `NSScreen.screens` entirely, so
    /// "is this the built-in display" is never a valid test for "does this have
    /// a notch".
    func testClamshellHasNoPhysicalNotchAnywhere() {
        let result = geometries(ScreenFixtures.clamshell)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.style == .synthetic })
    }

    func testZeroScreensProducesNoPanels() {
        XCTAssertTrue(geometries([]).isEmpty)
    }

    func testOnePanelPerScreen() {
        XCTAssertEqual(geometries(ScreenFixtures.founderDesk).count, 3)
    }

    /// The DebugBridge switch: the synthetic path is the primary development
    /// surface and has to be reachable on the notched built-in too.
    func testForceSyntheticOverridesARealNotch() {
        let result = geometries(
            [ScreenFixtures.notchedBuiltIn], GeometrySettings(forceSynthetic: true))
        XCTAssertEqual(result[0].style, .synthetic)
    }

    // MARK: - Synthetic geometry (D14)

    /// CONCEPT.md asks for "roughly half the width of a real one". Dictate draws
    /// it full width, so a naive port silently violates the requirement.
    func testSyntheticTabIsAboutHalfARealNotch() {
        let result = geometries(ScreenFixtures.founderDesk)
        let physical = try! XCTUnwrap(result.first { $0.style == .physical })
        let synthetic = try! XCTUnwrap(result.first { $0.style == .synthetic })
        XCTAssertEqual(synthetic.notch.width, (physical.notch.width * 0.5).rounded())
        XCTAssertEqual(synthetic.notch.width, 93)
    }

    func testSyntheticTabIsAboutHalfTheMenuBar() {
        let synthetic = geometries([ScreenFixtures.landscapeExternal])[0]
        let menuBar = ScreenFixtures.landscapeExternal.menuBarHeight
        XCTAssertEqual(synthetic.notch.height, (menuBar * 0.5).rounded())
        XCTAssertGreaterThanOrEqual(synthetic.notch.height, 10)
        XCTAssertLessThanOrEqual(synthetic.notch.height, 16)
    }

    /// With "Displays have separate Spaces" off, a secondary display reports no
    /// menu-bar inset at all. Without a fallback the tab would be zero-height
    /// and invisible.
    func testScreenWithNoMenuBarStillGetsAVisibleTab() {
        let synthetic = geometries([ScreenFixtures.noMenuBar])[0]
        XCTAssertGreaterThanOrEqual(synthetic.notch.height, 10)
    }

    /// A projector or a narrow vertical panel should not get a tab running half
    /// its width.
    func testSyntheticTabIsCappedOnNarrowScreens() {
        let synthetic = geometries([ScreenFixtures.narrow])[0]
        XCTAssertLessThanOrEqual(synthetic.notch.width, 600 * 0.4)
    }

    func testSyntheticTabIsCentredAndFlushWithTheTopEdge() {
        for screen in [ScreenFixtures.landscapeExternal, ScreenFixtures.portraitExternal] {
            let synthetic = geometries([screen])[0]
            XCTAssertEqual(synthetic.notch.midX, screen.frame.midX, accuracy: 1)
            XCTAssertEqual(synthetic.notch.maxY, screen.frame.maxY)
        }
    }

    // MARK: - Panel clamp (D8)

    func testPanelUsesThePreferredSizeWhenItFits() {
        let panel = geometries([ScreenFixtures.landscapeExternal])[0].panel
        XCTAssertEqual(panel.size, PanelSettings.defaultSize)
    }

    /// Dictate never implemented this clamp. An 880×580 panel does not fit an
    /// 800×600 display.
    func testPanelIsClampedToASmallScreen() {
        let panel = geometries([ScreenFixtures.tiny])[0].panel
        XCTAssertLessThanOrEqual(panel.width, 800)
        XCTAssertLessThanOrEqual(panel.height, 600)
        XCTAssertGreaterThanOrEqual(panel.width, GeometrySettings.minPanelWidth)
    }

    /// If even the 640×420 floor does not fit, a panel is still created and left
    /// to clip: a missing tab reads as a crash, a clipped panel reads as a small
    /// screen.
    func testPanelIsStillCreatedWhenTheFloorDoesNotFit() {
        let result = geometries([ScreenFixtures.narrow])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].panel.width, GeometrySettings.minPanelWidth)
    }

    /// The top edge uses `frame`, not `visibleFrame`: the slab is meant to
    /// overlap the menu bar.
    func testPanelIsPinnedToTheScreenTopEdge() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertEqual(geometry.panel.maxY, geometry.screen.maxY)
        }
    }

    func testPanelStaysInsideItsScreenHorizontally() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertGreaterThanOrEqual(geometry.panel.minX, geometry.screen.minX)
            XCTAssertLessThanOrEqual(geometry.panel.maxX, geometry.screen.maxX)
        }
    }

    func testEachScreenKeepsItsOwnPanel() {
        let result = geometries(ScreenFixtures.founderDesk)
        for geometry in result {
            XCTAssertTrue(geometry.screen.contains(CGPoint(
                x: geometry.panel.midX, y: geometry.panel.midY)))
        }
        XCTAssertEqual(Set(result.map(\.screenUUID)).count, 3)
    }

    // MARK: - Hit regions

    /// `NSRect.contains` excludes the max edge, and a pointer pressed against
    /// the top of the screen reports exactly `frame.maxY`. The trigger has to
    /// overhang, or sliding along the menu bar into the notch never opens it.
    func testTriggerOverhangsTheTopOfTheScreen() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertGreaterThan(geometry.trigger.maxY, geometry.screen.maxY)
        }
    }

    /// Dictate's numbers: ±6 pt sideways, 6 pt of slack under the thin tab,
    /// 4 pt of overhang above the screen edge.
    func testSyntheticTriggerIsGenerousEnoughToHit() {
        let synthetic = geometries([ScreenFixtures.landscapeExternal])[0]
        XCTAssertEqual(synthetic.trigger.width, synthetic.notch.width + 12)
        XCTAssertEqual(synthetic.trigger.height, synthetic.notch.height + 10)
    }

    /// Same max-edge problem, and it bites harder: the panel's top edge *is* the
    /// screen's top edge, so a pointer parked against the top would fall out of
    /// `hold`, the panel would fold, and the trigger would immediately catch it
    /// again — flickering forever.
    func testHoldOverhangsTheTopOfTheScreen() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertGreaterThan(geometry.hold.maxY, geometry.panel.maxY)
        }
    }

    /// Dictate's single dwell: 150 ms on every anchor style.
    func testDwellMatchesDictate() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertEqual(geometry.dwell, .milliseconds(150))
        }
    }

    /// The collapsed tab folds into the anchor and the expanded panel drops
    /// straight down from it — both share the anchor's vertical axis. Session
    /// 2's chrome aligned the collapsed tab to the panel's *leading edge*
    /// instead: the tab sat ~390 pt left of the notch, outside the hover
    /// trigger, and the panel looked unopenable. The geometry contract this
    /// guards: panel and anchor are concentric, so a centre-aligned chrome is
    /// correct on every screen.
    func testPanelIsCentredOnTheAnchorAxis() {
        for geometry in geometries(ScreenFixtures.founderDesk) {
            XCTAssertEqual(geometry.panel.midX, geometry.notch.midX, accuracy: 1)
        }
    }

    // MARK: - Reconfiguration diffing

    /// Clamshell fires `didChangeScreenParameters` several times inside a
    /// second; rebuilding on each makes the panel flash three to five times.
    func testIdenticalSnapshotsCompareEqual() {
        XCTAssertEqual(
            ScreenConfiguration(ScreenFixtures.founderDesk),
            ScreenConfiguration(ScreenFixtures.founderDesk))
    }

    /// macOS does not promise a stable ordering of `NSScreen.screens`, and a
    /// reordered array is not a reconfiguration.
    func testSnapshotIsOrderIndependent() {
        XCTAssertEqual(
            ScreenConfiguration(ScreenFixtures.founderDesk),
            ScreenConfiguration(ScreenFixtures.founderDesk.reversed()))
    }

    func testRealChangesCompareUnequal() {
        XCTAssertNotEqual(
            ScreenConfiguration(ScreenFixtures.founderDesk),
            ScreenConfiguration(ScreenFixtures.clamshell))

        // Menu bar auto-hiding changes safeAreaTop, which changes the geometry.
        XCTAssertNotEqual(
            ScreenConfiguration([ScreenFixtures.notchedBuiltIn]),
            ScreenConfiguration([ScreenFixtures.notchedWithHiddenMenuBar]))
    }

    /// Two displays mirrored to the same frame must still produce two panels
    /// keyed on their own UUIDs, not collapse into one.
    func testMirroredDisplaysStayDistinct() {
        let a = ScreenFixtures.landscapeExternal
        let b = ScreenInfo(
            uuid: "mirror",
            frame: a.frame,
            visibleFrame: a.visibleFrame,
            backingScaleFactor: a.backingScaleFactor)
        let result = geometries([a, b])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.screenUUID)), ["landscape", "mirror"])
    }
}
