import AppKit
import SwiftUI

/// Where a message sits inside its run, and what decorations that position
/// carries. Computed once per row build in `ConversationView.rows`.
struct MessageRowContext: Equatable {
    var isFirstInGroup: Bool
    var isLastInGroup: Bool
    var showsSender: Bool
    /// Reserve the avatar column at all (groups only, incoming only)…
    var showsAvatar: Bool
    /// …and draw the picture at the run's last message.
    var senderPhotoFileId: Int?
    /// The message this one answers, when it is in the loaded window.
    var reply: ReplyQuote? = nil
}

/// The quoted strip at the top of a reply: who said it and one line of what.
struct ReplyQuote: Equatable {
    var senderName: String
    var senderUserId: Int64
    var isOutgoing: Bool
    var text: String
}

/// One message bubble, Telegram-Desktop-shaped (P3): incoming left, outgoing
/// right, tinted, with the meta line tucked into the bottom-right corner and
/// corners that tighten inside a run.
struct MessageBubbleView: View {
    let item: MessageItem
    let fileStore: FileStore
    var context: MessageRowContext = MessageRowContext(
        isFirstInGroup: true, isLastInGroup: true,
        showsSender: false, showsAvatar: false, senderPhotoFileId: nil)
    let maxWidth: CGFloat
    var onRetry: () -> Void = {}
    /// Photos/videos route into the in-panel viewer with their message id.
    var onOpenMedia: (Int64) -> Void = { _ in }
    /// Voice/video notes route their transcription request.
    var onTranscribe: (Int64) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if item.isOutgoing {
                Spacer(minLength: 40)
            } else if context.showsAvatar {
                senderAvatar
            }

            bubble

            if !item.isOutgoing { Spacer(minLength: 40) }
        }
        .accessibilityIdentifier("message-\(item.messageId)")
    }

    // MARK: - Avatar column

    @ViewBuilder
    private var senderAvatar: some View {
        let side = Theme.Metrics.messageAvatar
        Group {
            if context.isLastInGroup {
                ZStack {
                    Circle().fill(Theme.Palette.avatarColor(for: item.senderUserId))
                    Text(Self.initials(item.senderName))
                        .font(.system(size: side * 0.36, weight: .medium))
                        .foregroundStyle(.white)
                    if let fileId = context.senderPhotoFileId {
                        MediaImage(
                            url: fileStore.localURL(for: fileId),
                            targetSize: CGSize(width: side, height: side)
                        ) { Color.clear }
                        .onAppear { fileStore.requestDownload(fileId, priority: 8) }
                    }
                }
                .frame(width: side, height: side)
                .clipShape(Circle())
            } else {
                Color.clear.frame(width: side, height: 1)
            }
        }
    }

    /// Message text with its links made live and tinted. Entity offsets are
    /// UTF-16 units, so the ranges are resolved through the UTF-16 view — an
    /// emoji earlier in the line would otherwise shift every link after it.
    /// A link that does not land on character boundaries is skipped rather
    /// than mis-drawn.
    static func linkified(_ text: String, links: [TextLink]) -> AttributedString {
        var attributed = AttributedString(text)
        guard !links.isEmpty else { return attributed }
        let utf16 = text.utf16
        for link in links {
            guard link.offset >= 0, link.length > 0,
                  link.offset + link.length <= utf16.count,
                  let url = URL(string: link.url),
                  let lower = utf16.index(utf16.startIndex, offsetBy: link.offset)
                    .samePosition(in: text),
                  let upper = utf16.index(utf16.startIndex, offsetBy: link.offset + link.length)
                    .samePosition(in: text),
                  let start = AttributedString.Index(lower, within: attributed),
                  let end = AttributedString.Index(upper, within: attributed)
            else { continue }
            attributed[start..<end].link = url
            attributed[start..<end].foregroundColor = Theme.Palette.accent
            attributed[start..<end].underlineStyle = .single
        }
        return attributed
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined().uppercased()
    }

    // MARK: - Bubble

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            if context.showsSender {
                Text(item.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.senderColor(for: item.senderUserId))
            }
            if let reply = context.reply {
                replyStrip(reply)
            }
            content
            if !item.reactions.isEmpty {
                reactionsRow
            }
        }
        .padding(.horizontal, Theme.Metrics.bubblePaddingH)
        .padding(.top, Theme.Metrics.bubblePaddingV)
        // Room reserved for the meta line, which is overlaid rather than
        // laid out: a `Spacer` in the bubble would make it greedy and every
        // bubble would stretch to the full column width. Telegram tucks the
        // time into the bottom-right corner for the same reason.
        .padding(.bottom, Theme.Metrics.bubblePaddingV + 8)
        .padding(.trailing, metaReserve)
        // Stickers and round messages get no bubble — Telegram draws them bare
        // on the background, and a tinted rectangle behind one looks wrong.
        .background(
            isBareMedia
                ? Color.clear
                : (item.isOutgoing ? Theme.Palette.bubbleOut : Theme.Palette.bubbleIn),
            in: bubbleShape)
        // Edge light: glass reads as glass only if its rim catches light.
        .overlay {
            if !isBareMedia {
                bubbleShape.strokeBorder(
                    item.isOutgoing
                        ? Theme.Palette.bubbleOutStroke
                        : Theme.Palette.bubbleInStroke,
                    lineWidth: 1)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            metaLine
                .padding(.horizontal, hasMediaTail ? 7 : 0)
                .padding(.vertical, hasMediaTail ? 3 : 0)
                .background(hasMediaTail ? Color.black.opacity(0.45) : .clear, in: .capsule)
                .padding(.trailing, hasMediaTail ? 6 : Theme.Metrics.bubblePaddingH)
                .padding(.bottom, hasMediaTail ? 6 : 4)
        }
        .frame(maxWidth: maxWidth, alignment: item.isOutgoing ? .trailing : .leading)
        .opacity(isPending ? 0.65 : 1)
        .contextMenu {
            if let text = item.text {
                Button(L10n.s("Copy", "Копировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            if case .failed = item.status {
                Button(L10n.s("Retry", "Повторить"), action: onRetry)
            }
        }
    }

    /// Corners tighten on the side facing the run's neighbours — Telegram's
    /// grouped-bubble look.
    private var bubbleShape: UnevenRoundedRectangle {
        let big = Theme.Metrics.bubbleCornerRadius
        let tight = Theme.Metrics.bubbleCornerRadiusTight
        let top = context.isFirstInGroup ? big : tight
        let bottom = context.isLastInGroup ? big : tight
        return item.isOutgoing
            ? UnevenRoundedRectangle(
                topLeadingRadius: big, bottomLeadingRadius: big,
                bottomTrailingRadius: bottom, topTrailingRadius: top)
            : UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom,
                bottomTrailingRadius: big, topTrailingRadius: big)
    }

    /// Enough trailing space that the overlaid time never sits on the text.
    private var metaReserve: CGFloat {
        var width: CGFloat = 34
        if item.isOutgoing { width += 14 }
        if item.isEdited { width += 34 }
        if case .failed = item.status { width += 26 }
        return width
    }

    /// Telegram's reply quote: an accent rule, the quoted sender in their
    /// identity colour, one line of the quoted message.
    private func replyStrip(_ reply: ReplyQuote) -> some View {
        let tint = reply.isOutgoing
            ? Theme.Palette.accent
            : Theme.Palette.senderColor(for: reply.senderUserId)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(reply.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Text(reply.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 6))
        .padding(.bottom, 2)
        .accessibilityIdentifier("message-reply-quote")
    }

    @ViewBuilder
    private var content: some View {
        if let text = item.text {
            Text(Self.linkified(text, links: item.textLinks))
                .font(Theme.Fonts.messageBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MediaContentView(
                item: item,
                fileStore: fileStore,
                // The bubble reserves room for the overlaid time; media has to
                // fit inside what is left or the corner clips it.
                maxWidth: maxWidth - metaReserve - Theme.Metrics.bubblePaddingH * 2,
                onOpenMedia: onOpenMedia,
                onTranscribe: onTranscribe)
        }
    }

    // MARK: - Reactions

    private var reactionsRow: some View {
        HStack(spacing: 4) {
            ForEach(item.reactions, id: \.emoji) { reaction in
                HStack(spacing: 3) {
                    Text(reaction.emoji).font(.system(size: 11))
                    Text("\(reaction.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(
                            reaction.isChosen
                                ? Color.black.opacity(0.8)
                                : Theme.Palette.accent)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    reaction.isChosen ? Theme.Palette.accent : Theme.Palette.accentMuted,
                    in: .capsule)
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("message-reactions")
    }

    // MARK: - Meta

    private var metaColor: Color {
        if hasMediaTail { return .white }
        return item.isOutgoing ? Theme.Palette.bubbleOutMeta : Theme.Palette.bubbleInMeta
    }

    /// The meta line sits on top of pixels (a photo, a video frame) rather
    /// than on bubble tint — give it Telegram's dark scrim capsule.
    private var hasMediaTail: Bool {
        switch item.content {
        case .messagePhoto(let value): value.caption.text.isEmpty
        case .messageVideo(let value): value.caption.text.isEmpty
        case .messageAnimation(let value): value.caption.text.isEmpty
        case .messageVideoNote: true
        default: false
        }
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            if item.isEdited {
                Text(L10n.s("edited", "изменено"))
                    .font(Theme.Fonts.messageMeta)
                    .foregroundStyle(metaColor)
            }
            Text(Self.time(item.date))
                .font(Theme.Fonts.messageMeta)
                .monospacedDigit()
                .foregroundStyle(metaColor)
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if item.isOutgoing {
            switch item.status {
            case .pending:
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(metaColor)
                    .accessibilityIdentifier("message-pending")
            case .sent:
                DeliveryTicks(
                    read: item.isReadByPeer,
                    color: item.isReadByPeer ? Theme.Palette.accent : metaColor)
                    .accessibilityIdentifier(item.isReadByPeer ? "message-read" : "message-sent")
            case .failed(let reason):
                Button(action: onRetry) {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text(L10n.s("Retry", "Повторить"))
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.destructive)
                }
                .buttonStyle(.plain)
                .help(reason)
                .accessibilityIdentifier("message-failed")
            }
        }
    }

    private var isBareMedia: Bool {
        switch item.content {
        case .messageSticker, .messageVideoNote: true
        default: false
        }
    }

    private var isPending: Bool {
        if case .pending = item.status { return true }
        return false
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func time(_ unix: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

/// The centred line that separates days, and the one service messages use.
/// A dark scrim disappears on the black ground — this is a quiet glass chip.
struct ConversationSeparatorView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.055), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

/// Telegram's "Unread messages" bar — the full-width strip a chat opens at
/// when there is something unread.
struct UnreadDividerView: View {
    var body: some View {
        Text(L10n.s("Unread messages", "Непрочитанные сообщения"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.045))
            .padding(.vertical, 2)
            .accessibilityIdentifier("unread-divider")
    }
}
