import SwiftUI

/// One chat-list row, at Telegram Desktop's density (P3).
struct ChatRowView: View {
    let summary: ChatSummary
    let fileStore: FileStore
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(summary: summary, fileStore: fileStore)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .accessibilityIdentifier("chat-pinned")
                    }
                    Text(summary.title)
                        .font(Theme.Fonts.chatTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    if summary.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .accessibilityIdentifier("chat-muted")
                    }
                    Spacer(minLength: 4)
                    ticks
                    Text(Self.timestamp(summary.date))
                        .font(Theme.Fonts.chatTimestamp)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .monospacedDigit()
                }

                HStack(spacing: 6) {
                    if summary.hasDraft {
                        Text(L10n.s("Draft:", "Черновик:"))
                            .font(Theme.Fonts.chatPreview)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                    Text(summary.preview)
                        .font(Theme.Fonts.chatPreview)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.chatRowHeight)
        .background(rowBackground)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("chat-row-\(summary.id)")
    }

    /// Selection is a glass pill with an edge-light hairline, not a colored
    /// block — color stays reserved for unread/meaning.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(isSelected
                ? Theme.Palette.surfaceSelected
                : (isHovering ? Theme.Palette.surfaceHover : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        isSelected ? Theme.Palette.hairline : .clear, lineWidth: 1)
            }
            .padding(.horizontal, 4)
            .animation(Theme.Motion.quick, value: isHovering)
            .animation(Theme.Motion.quick, value: isSelected)
    }

    /// Read state has no per-message update; it comes from comparing the last
    /// message id against the chat's `last_read_outbox_message_id`.
    @ViewBuilder
    private var ticks: some View {
        if summary.showsReadTicks {
            DeliveryTicks(read: true, color: Theme.Palette.accent)
                .accessibilityIdentifier("chat-read")
        } else if summary.showsUnreadTicks {
            DeliveryTicks(read: false, color: Theme.Palette.textTertiary)
                .accessibilityIdentifier("chat-sent")
        }
    }

    /// The ice accent is light, so badge text is ink-on-ice, not white-on-blue.
    @ViewBuilder
    private var badges: some View {
        if summary.unreadMentionCount > 0 {
            Text("@")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Theme.Palette.accent, in: .circle)
        }
        if summary.unreadCount > 0 {
            Text(Self.badgeText(summary.unreadCount))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(
                    summary.isMuted ? Theme.Palette.textSecondary : Color.black.opacity(0.8))
                .padding(.horizontal, 6)
                .frame(minWidth: 18, minHeight: 18)
                // Muted chats still show a count, just a quiet glass one — same
                // as Telegram, and the reason "unread" and "should notify" are
                // two different questions.
                .background(
                    summary.isMuted ? Color.white.opacity(0.12) : Theme.Palette.accent,
                    in: .capsule)
                .contentTransition(.numericText())
                .animation(Theme.Motion.quick, value: summary.unreadCount)
                .accessibilityIdentifier("chat-unread-\(summary.unreadCount)")
        } else if summary.isMarkedAsUnread {
            Circle()
                .fill(summary.isMuted ? Theme.Palette.textTertiary : Theme.Palette.accent)
                .frame(width: 10, height: 10)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.dateLocale
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yy"
        return formatter
    }()

    /// Telegram's rule: today shows a clock, this week a weekday, older a date.
    /// Formatters are cached — allocating one per row per body pass was a
    /// visible slice of every list update in Session 1's profile.
    static func timestamp(_ unix: Int) -> String {
        guard unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: Date()), date > weekAgo {
            return weekdayFormatter.string(from: date)
        }
        return dateOnlyFormatter.string(from: date)
    }

    static func badgeText(_ count: Int) -> String {
        count > 999 ? "999+" : String(count)
    }
}
