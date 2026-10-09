import AppKit
import SwiftUI

/// A `media_album_id` run rendered as one Telegram-style post: the photos and
/// videos tile into a mosaic inside a single bubble, with one caption and one
/// meta line — never a column of separate media messages (C4).
struct AlbumBubbleView: View {
    let items: [MessageItem]
    let fileStore: FileStore
    var context: MessageRowContext
    let maxWidth: CGFloat
    var onOpenMedia: (Int64) -> Void = { _ in }

    private var first: MessageItem { items[0] }
    private var last: MessageItem { items[items.count - 1] }

    /// The album's one caption: Telegram allows a caption per item but shows
    /// a combined album caption only when exactly one item carries text.
    private var caption: String? {
        let captions = items.compactMap { item -> String? in
            switch MediaDescriptor.from(item.content) {
            case .photo(let photo): photo.caption.isEmpty ? nil : photo.caption
            case .video(let video): video.caption.isEmpty ? nil : video.caption
            default: nil
            }
        }
        return captions.count == 1 ? captions[0] : nil
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if first.isOutgoing {
                Spacer(minLength: 40)
            } else if context.showsAvatar {
                senderAvatar
            }

            bubble

            if !first.isOutgoing { Spacer(minLength: 40) }
        }
        .accessibilityIdentifier("album-\(first.messageId)")
    }

    // MARK: - Bubble

    private let mosaicWidth: CGFloat = 300

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if context.showsSender {
                Text(first.senderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.senderColor(for: first.senderUserId))
                    .padding(.horizontal, Theme.Metrics.bubblePaddingH)
                    .padding(.top, Theme.Metrics.bubblePaddingV)
                    .padding(.bottom, 2)
            }

            AlbumMosaic(
                items: items,
                fileStore: fileStore,
                width: min(mosaicWidth, maxWidth),
                onOpenMedia: onOpenMedia)

            if let caption {
                Text(caption)
                    .font(Theme.Fonts.messageBody)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metrics.bubblePaddingH)
                    .padding(.top, Theme.Metrics.bubblePaddingV)
                    .padding(.bottom, Theme.Metrics.bubblePaddingV + 8)
            }
        }
        .background(
            first.isOutgoing ? Theme.Palette.bubbleOut : Theme.Palette.bubbleIn,
            in: bubbleShape)
        .clipShape(bubbleShape)
        .overlay(alignment: .bottomTrailing) {
            metaLine
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(caption == nil ? Color.black.opacity(0.45) : .clear, in: .capsule)
                .padding(.trailing, 6)
                .padding(.bottom, caption == nil ? 6 : 4)
        }
        .frame(maxWidth: maxWidth, alignment: first.isOutgoing ? .trailing : .leading)
        .contextMenu {
            if let caption {
                Button(L10n.s("Copy", "Копировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(caption, forType: .string)
                }
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let big = Theme.Metrics.bubbleCornerRadius
        let tight = Theme.Metrics.bubbleCornerRadiusTight
        let top = context.isFirstInGroup ? big : tight
        let bottom = context.isLastInGroup ? big : tight
        return first.isOutgoing
            ? UnevenRoundedRectangle(
                topLeadingRadius: big, bottomLeadingRadius: big,
                bottomTrailingRadius: bottom, topTrailingRadius: top)
            : UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom,
                bottomTrailingRadius: big, topTrailingRadius: big)
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(MessageBubbleView.time(last.date))
                .font(Theme.Fonts.messageMeta)
                .monospacedDigit()
            if last.isOutgoing {
                Text(last.isReadByPeer ? "✓✓" : "✓")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(caption == nil
            ? Color.white
            : (last.isOutgoing ? Theme.Palette.bubbleOutMeta : Theme.Palette.bubbleInMeta))
    }

    @ViewBuilder
    private var senderAvatar: some View {
        let side = Theme.Metrics.messageAvatar
        if context.isLastInGroup {
            ZStack {
                Circle().fill(Theme.Palette.avatarColor(for: first.senderUserId))
                Text(MessageBubbleView.initials(first.senderName))
                    .font(.system(size: side * 0.36, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: side, height: side)
            .clipShape(Circle())
        } else {
            Color.clear.frame(width: side, height: 1)
        }
    }
}

/// The tiling itself. A simplified take on tdesktop's grouped-media layout:
/// items chunk into rows by count, each row's height comes from making its
/// cells' aspect ratios fill the album width exactly.
struct AlbumMosaic: View {
    let items: [MessageItem]
    let fileStore: FileStore
    let width: CGFloat
    var onOpenMedia: (Int64) -> Void

    private static let spacing: CGFloat = 2

    var body: some View {
        let layout = Self.layout(for: items, width: width)
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(0..<layout.count, id: \.self) { rowIndex in
                HStack(spacing: Self.spacing) {
                    ForEach(layout[rowIndex], id: \.item.id) { cell in
                        AlbumCellView(
                            item: cell.item,
                            fileStore: fileStore,
                            size: cell.size,
                            onOpen: onOpenMedia)
                    }
                }
            }
        }
        .frame(width: width)
    }

    struct Cell {
        let item: MessageItem
        let size: CGSize
    }

    /// Cells per row, tdesktop-flavoured: a leading hero row for odd counts,
    /// then rows of two or three.
    static func rowPattern(_ count: Int) -> [Int] {
        switch count {
        case ...1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        case 5: [2, 3]
        case 6: [3, 3]
        case 7: [1, 3, 3]
        case 8: [2, 3, 3]
        case 9: [3, 3, 3]
        default: [1, 3, 3, 3]
        }
    }

    static func aspect(of item: MessageItem) -> CGFloat {
        let raw: CGFloat
        switch MediaDescriptor.from(item.content) {
        case .photo(let photo): raw = photo.aspectRatio
        case .video(let video):
            raw = video.height > 0 ? CGFloat(video.width) / CGFloat(video.height) : 1.3
        default: raw = 1
        }
        // Degenerate panoramas/stripes would starve their row-mates.
        return min(max(raw, 0.55), 2.2)
    }

    static func layout(for items: [MessageItem], width: CGFloat) -> [[Cell]] {
        var rows: [[Cell]] = []
        var cursor = 0
        for rowCount in rowPattern(items.count) where cursor < items.count {
            let slice = Array(items[cursor..<min(cursor + rowCount, items.count)])
            cursor += slice.count
            let spacingTotal = CGFloat(slice.count - 1) * spacing
            let usable = width - spacingTotal
            let aspectSum = slice.reduce(CGFloat(0)) { $0 + aspect(of: $1) }
            let height = min(max(usable / max(aspectSum, 0.1), 72), 240)
            var cells = slice.map {
                Cell(item: $0, size: CGSize(width: height * aspect(of: $0), height: height))
            }
            // Absorb rounding drift so every row is exactly `width` wide.
            let widthSum = cells.reduce(CGFloat(0)) { $0 + $1.size.width }
            let correction = (usable - widthSum) / CGFloat(cells.count)
            cells = cells.map {
                Cell(item: $0.item, size: CGSize(
                    width: $0.size.width + correction, height: $0.size.height))
            }
            rows.append(cells)
        }
        return rows
    }
}

private struct AlbumCellView: View {
    let item: MessageItem
    let fileStore: FileStore
    let size: CGSize
    var onOpen: (Int64) -> Void

    @Environment(\.displayScale) private var scale

    var body: some View {
        Button {
            onOpen(item.messageId)
        } label: {
            ZStack {
                switch MediaDescriptor.from(item.content) {
                case .photo(let photo):
                    MinithumbImage(data: photo.minithumbnail, blur: 4)
                    MediaImage(
                        url: photoURL(photo),
                        targetSize: size
                    ) { Color.clear }
                case .video(let video):
                    MinithumbImage(data: video.minithumbnail, blur: 4)
                    if let thumbnailId = video.thumbnailFileId {
                        MediaImage(
                            url: fileStore.localURL(for: thumbnailId),
                            targetSize: size
                        ) { Color.clear }
                    }
                    durationBadge(video.duration)
                default:
                    Color.black.opacity(0.3)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onAppear(perform: request)
    }

    private func photoURL(_ photo: PhotoDescriptor) -> URL? {
        photo.bestSize(forWidth: size.width, scale: scale)
            .flatMap { fileStore.localURL(for: $0.fileId) }
    }

    private func request() {
        switch MediaDescriptor.from(item.content) {
        case .photo(let photo):
            if let best = photo.bestSize(forWidth: size.width, scale: scale) {
                fileStore.requestDownload(best.fileId)
            }
        case .video(let video):
            if let thumbnailId = video.thumbnailFileId {
                fileStore.requestDownload(thumbnailId, priority: 8)
            }
        default:
            break
        }
    }

    private func durationBadge(_ seconds: Int) -> some View {
        VStack {
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                    Text(formatDuration(seconds)).monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
                Spacer()
            }
            Spacer()
        }
        .padding(5)
    }
}
