// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import Foundation

/// Wire types for the DebugBridge loopback control channel (D18).
///
/// The bridge exists so an agent can drive and observe every UI state without a
/// physical mouse hover. It is compiled into **Debug builds only** (D43,
/// amending D18): the public Release build is distributed to strangers and must
/// not carry an unauthenticated control socket. Even in Debug the listener only
/// starts when explicitly enabled.

/// `POST /command` body. Modelled as one struct with optional arguments rather
/// than a Codable enum so adding a command never breaks an older harness script.
struct DebugCommandRequest: Decodable, Sendable {
    var command: String
    /// `setSize`
    var width: Double?
    var height: Double?
    /// `openChat`
    var chatId: Int64?
    /// `screenshot` — absolute destination path for the in-app capture.
    var path: String?
    /// `gotoAuthState`
    var state: String?
    /// `forceSynthetic`
    var enabled: Bool?
    /// Which screen to act on, by display UUID. Defaults to the screen the
    /// pointer is on, else the first.
    var screen: String?
}

/// One panel, one screen. Mirrors what `NotchGeometryEngine` resolved, so
/// geometry assertions are diffable instead of a screenshot squint.
struct DebugPanelStatus: Encodable, Sendable {
    var screenUUID: String
    var screenFrame: [Double]      // x, y, w, h
    var visibleFrame: [Double]
    var isPhysicalNotch: Bool
    var notchRect: [Double]
    var triggerRect: [Double]
    var panelSize: [Double]
    var state: String              // collapsed | expanding | expanded | collapsing
    var windowNumber: Int
    var alpha: Double
    var isCovered: Bool
    var ignoresMouseEvents: Bool
    var isKeyWindow: Bool
}

/// `GET /status`, and the body every command returns *after* its transition has
/// settled — so a caller never races the ~450 ms unfold spring.
struct DebugStatus: Encodable, Sendable {
    var app: String = "NotchGram"
    var version: String
    var build: String
    var pid: Int32
    var configuration: String
    /// True when running `NOTCHGRAM_DEMO=1` fixture content with no TDLib
    /// client. Capture scripts must check this before taking any picture.
    var demo: Bool
    var tdlibVersion: String?
    var authState: String
    var connectionState: String
    var activeAccountId: String?
    var openChatId: Int64?
    /// The expanded panel's window number, or the first panel's when collapsed.
    /// `screencapture -l` takes this.
    var windowNumber: Int
    var panelState: String
    var focusedField: String?
    var focusedFieldText: String?
    var frontmostApp: String?
    var isKeyWindow: Bool
    /// Hold reasons currently keeping the panel open (`activePins`), plus
    /// whether a DebugBridge force-expand is latched — the exact state the
    /// stuck-panel triage asked for.
    var activePins: [String]?
    var isDebugForced: Bool?
    var panels: [DebugPanelStatus]
    var screens: Int
    /// SMAppService state, so launch-at-login is checkable from a script
    /// rather than by squinting at a screenshot.
    var loginItem: String?
    var error: String?
}

struct DebugError: Encodable, Sendable {
    var error: String
}

#endif
