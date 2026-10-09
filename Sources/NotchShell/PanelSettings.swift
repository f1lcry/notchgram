import CoreGraphics
import Foundation
import Observation

/// Panel preferences, persisted to `UserDefaults`.
///
/// `UserDefaults` is injected rather than reached for, which is the same pattern
/// Dictate uses and the reason settings can be exercised against an ephemeral
/// suite in tests instead of polluting the founder's real domain.
@MainActor
@Observable
public final class PanelSettings {
    public enum Key {
        public static let panelWidth = "PanelWidth"
        public static let panelHeight = "PanelHeight"
        public static let forceSynthetic = "ForceSyntheticNotch"
        public static let collapsedUnreadBadge = "CollapsedUnreadBadge"
    }

    /// D8: the founder's Telegram Desktop measured 890×584 on 2026-08-22.
    public static let defaultSize = CGSize(width: 880, height: 580)

    /// Presets offered in Settings alongside a custom size.
    public static let presets: [(name: String, size: CGSize)] = [
        ("Compact", CGSize(width: 680, height: 460)),
        ("Default", defaultSize),
        ("Large", CGSize(width: 1040, height: 680)),
    ]

    private let defaults: UserDefaults

    public var panelSize: CGSize {
        didSet {
            defaults.set(Double(panelSize.width), forKey: Key.panelWidth)
            defaults.set(Double(panelSize.height), forKey: Key.panelHeight)
        }
    }

    /// Draw a synthetic tab even on a display that has a real cut-out. The
    /// synthetic path is the primary development surface — the founder works on
    /// external, notch-less displays — so it has to be reachable everywhere.
    public var forceSynthetic: Bool {
        didSet { defaults.set(forceSynthetic, forKey: Key.forceSynthetic) }
    }

    /// D10: the collapsed state is fully passive by default. The unread badge is
    /// available but off, because a badge in the notch is exactly the kind of
    /// thing that makes a passive surface stop being passive.
    public var showsCollapsedUnreadBadge: Bool {
        didSet { defaults.set(showsCollapsedUnreadBadge, forKey: Key.collapsedUnreadBadge) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedWidth = defaults.object(forKey: Key.panelWidth) as? Double
        let storedHeight = defaults.object(forKey: Key.panelHeight) as? Double
        let width: CGFloat = storedWidth.map { CGFloat($0) } ?? Self.defaultSize.width
        let height: CGFloat = storedHeight.map { CGFloat($0) } ?? Self.defaultSize.height
        self.panelSize = CGSize(width: width, height: height)
        self.forceSynthetic = defaults.bool(forKey: Key.forceSynthetic)
        self.showsCollapsedUnreadBadge = defaults.bool(forKey: Key.collapsedUnreadBadge)
    }

    public var geometrySettings: GeometrySettings {
        GeometrySettings(panelSize: panelSize, forceSynthetic: forceSynthetic)
    }
}
