import Foundation
import Observation

/// Per-screen panel state. Deliberately small.
///
/// Everything that is about *the app* rather than *this screen* — the open chat,
/// the composer draft, the scroll anchor — lives in shared stores instead
/// (D15). That split is not tidiness: a display hot-plug rebuilds every panel,
/// and a half-typed message living on the panel would be eaten by it.
@MainActor
@Observable
public final class PanelState {
    public internal(set) var expanded = false
    /// True once the unfold spring has finished. Content that measures itself
    /// (a chat list, a message list) must not lay out mid-animation.
    public internal(set) var settled = false
    /// Whether the SwiftUI content tree exists at all.
    ///
    /// Dictate always lays its content out at full size and merely hides it with
    /// `.opacity(0)`. For a live chat list that would mean rendering — and
    /// holding — every row for a panel nobody has opened. Content is mounted on
    /// expand and unmounted once the fold has finished.
    public internal(set) var mounted = false
    /// A full-screen window owns this display. Per D22 the panel does not order
    /// out — it goes transparent and click-through, so a non-hover expand can
    /// still summon it over the fullscreen Space.
    public internal(set) var isCovered = false
    public internal(set) var pointerInside = false

    public init() {}
}

/// Cross-screen application state that must survive a rebuild.
///
/// A display change tears down every panel and builds new ones. Anything the
/// user is in the middle of has to live here, or it disappears with the window.
@MainActor
@Observable
public final class PanelSharedState {
    /// What the right-hand pane shows.
    public enum Pane: String, Equatable, Sendable {
        case conversation, settings, profile
    }

    public var activePane: Pane = .conversation
    /// The chat currently open, if any. One at a time, across all screens.
    public var openChatId: Int64?
    /// Per-chat composer drafts. **This is why the shared store exists**: a
    /// hot-plug rebuild with the draft on the panel silently eats a half-typed
    /// message — a failure mode Dictate cannot have, because it has no text
    /// input at all.
    public var composerDrafts: [Int64: String] = [:]
    /// A reason the panel is currently held open regardless of the pointer.
    ///
    /// Session 4's single boolean latch had five uncoordinated writers, none of
    /// which fired on view teardown — ordinary navigation destroyed the view
    /// before its releasing edge, latching the panel open forever (the
    /// founder's "the window got stuck"). Each reason is now owned by exactly one UI
    /// surface, which clears it both on the state's falling edge *and* in
    /// `onDisappear`; a later writer of one reason can no longer clobber
    /// another's hold.
    public enum PinReason: String, CaseIterable, Sendable {
        case composerFocus, searchFocus, authFocus, filePicker, pendingOutgoing
        /// The in-panel media viewer is open (possibly playing a video with
        /// the pointer parked elsewhere).
        case mediaViewer
    }

    /// Live set of hold reasons. Mutated only through
    /// `NotchController.setPin(_:_:)` so the hover state machine re-evaluates
    /// on the same tick.
    public internal(set) var activePins: Set<PinReason> = []
    /// Forced open by DebugBridge, independent of hover. This is what lets an
    /// agent drive every UI state without a physical pointer.
    public var isDebugForced = false

    public init() {}

    public func draft(for chatId: Int64) -> String {
        composerDrafts[chatId] ?? ""
    }

    public func setDraft(_ text: String, for chatId: Int64) {
        if text.isEmpty {
            composerDrafts.removeValue(forKey: chatId)
        } else {
            composerDrafts[chatId] = text
        }
    }
}
