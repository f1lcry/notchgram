import SwiftUI

/// The visual language, Session 7's "Obsidian" redesign: the panel *is* the
/// notch. One material — black glass — flowing out of the hardware cut-out
/// with no visible seam, which is why the shell is pure black and never a hue
/// (the founder's complaint about the blue slab: the notch read as a hole in
/// the app). Structure comes from whisper-quiet white elevation steps and
/// hairlines, never from color; color is one ice-cyan accent spent on meaning
/// (unread, send, focus, read). Bubbles are glass: graphite for incoming, ice
/// for outgoing. This supersedes P3's "Telegram Desktop night theme" — the
/// density stays Telegram's, the skin is NotchGram's own.
public enum Theme {

    // MARK: - Colour

    public enum Palette {
        /// The slab's fill while open. Pure black on purpose: it must be the
        /// same material as the collapsed notch, so the hardware boundary
        /// disappears. Everything lighter is painted *inside* the content.
        public static let panelShell = Color.black
        /// The panel's base coat — the ground every glass surface sits on.
        public static let background = Color.black
        /// Chat-list plane. Same ground as the canvas (a different color would
        /// split the slab into two worlds); the divider hairline is enough.
        public static let surface = Color.white.opacity(0.02)
        /// Header, composer, folder bar — one quiet step above the ground.
        public static let surfaceRaised = Color.white.opacity(0.05)
        /// The conversation canvas behind bubbles: bare ground.
        public static let chatCanvas = Color.clear
        public static let surfaceHover = Color.white.opacity(0.06)
        /// Selection is a glass pill, not a colored block — color stays
        /// reserved for meaning.
        public static let surfaceSelected = Color.white.opacity(0.11)

        public static let separator = Color.white.opacity(0.06)
        /// Edge light on glass surfaces (selection pills, fields, bubbles).
        public static let hairline = Color.white.opacity(0.08)

        public static let textPrimary = Color.white
        public static let textSecondary = Color.white.opacity(0.58)
        public static let textTertiary = Color.white.opacity(0.36)

        /// Ice cyan — Apple's dark-mode cyan, not Telegram's blue. The one
        /// color in the app.
        public static let accent = rgb(0x64D2FF)
        public static let accentMuted = rgb(0x64D2FF).opacity(0.14)
        public static let destructive = rgb(0xFF6B6B)
        public static let success = rgb(0x4DCC5E)

        /// Bubbles as glass over the black ground. Incoming graphite, outgoing
        /// ice — read at a glance by material, not by loud fill.
        public static let bubbleIn = Color.white.opacity(0.075)
        public static let bubbleInStroke = Color.white.opacity(0.05)
        public static let bubbleOut = rgb(0x64D2FF).opacity(0.16)
        public static let bubbleOutStroke = rgb(0x64D2FF).opacity(0.22)
        /// Meta text inside bubbles (time, ticks).
        public static let bubbleInMeta = Color.white.opacity(0.38)
        public static let bubbleOutMeta = rgb(0xA9DDFF).opacity(0.75)

        /// Sender-name tints inside group chats, tdesktop's classic eight —
        /// identity colors people already know their chats by.
        public static let senderColors: [Color] = [
            rgb(0xEE7F7F), rgb(0xE5B76A), rgb(0x9BD065), rgb(0x62D4CB),
            rgb(0x6FB1E4), rgb(0x8A9FEE), rgb(0xC689E2), rgb(0xEE7FB2),
        ]

        public static func senderColor(for id: Int64) -> Color {
            senderColors[Int(UInt64(bitPattern: id) % UInt64(senderColors.count))]
        }

        /// Avatar placeholder colours, picked deterministically from the chat id
        /// so the same chat always looks the same.
        public static let avatarColors: [Color] = [
            rgb(0xE56555), rgb(0xF28C48), rgb(0x8E85EE), rgb(0x76C84D),
            rgb(0x5FBED5), rgb(0x549CDD), rgb(0xD669ED), rgb(0xF2749A),
        ]

        public static func avatarColor(for id: Int64) -> Color {
            avatarColors[Int(UInt64(bitPattern: id) % UInt64(avatarColors.count))]
        }

        static func rgb(_ hex: UInt32) -> Color {
            Color(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255)
        }
    }

    // MARK: - Metrics

    public enum Metrics {
        /// Telegram Desktop's chat rows are dense; a notch panel has less height
        /// to spend than a full window, so this matters more here than there.
        public static let chatRowHeight: CGFloat = 56
        public static let chatRowAvatar: CGFloat = 40
        public static let chatListWidth: CGFloat = 268

        /// Grouped-bubble corners: the side facing the run's neighbour tightens.
        public static let bubbleCornerRadius: CGFloat = 15
        public static let bubbleCornerRadiusTight: CGFloat = 6
        public static let bubbleMaxWidthRatio: CGFloat = 0.72
        public static let bubblePaddingH: CGFloat = 10
        public static let bubblePaddingV: CGFloat = 6
        public static let bubbleSpacing: CGFloat = 2
        /// Extra gap where the sender changes, so a conversation reads as turns.
        public static let bubbleGroupSpacing: CGFloat = 10
        /// Avatar beside grouped incoming messages.
        public static let messageAvatar: CGFloat = 30

        public static let contentPadding: CGFloat = 12
        public static let composerMinHeight: CGFloat = 36
        public static let composerMaxHeight: CGFloat = 140
    }

    // MARK: - Motion

    /// One motion vocabulary for the whole panel — Apple's rules: fast,
    /// ease-out, transform/opacity only, felt rather than watched.
    public enum Motion {
        /// Hover tints, small reveals.
        public static let quick = Animation.easeOut(duration: 0.14)
        /// Pane and content swaps.
        public static let pane = Animation.spring(response: 0.30, dampingFraction: 0.86)
        /// The sliding selection pill (folder tabs).
        public static let pill = Animation.spring(response: 0.30, dampingFraction: 0.82)
        /// Playful state pops (send button arming, FAB).
        public static let pop = Animation.spring(response: 0.25, dampingFraction: 0.62)
        /// New rows entering the conversation.
        public static let insert = Animation.spring(response: 0.28, dampingFraction: 0.88)
    }

    // MARK: - Type

    public enum Fonts {
        public static let chatTitle = Font.system(size: 13, weight: .semibold)
        public static let chatPreview = Font.system(size: 12)
        public static let chatTimestamp = Font.system(size: 11)
        public static let messageBody = Font.system(size: 13)
        public static let messageMeta = Font.system(size: 10)
        public static let sectionHeader = Font.system(size: 11, weight: .semibold)
        public static let header = Font.system(size: 14, weight: .semibold)
    }
}
