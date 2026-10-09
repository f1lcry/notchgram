import SwiftUI
import UniformTypeIdentifiers

/// The open conversation: header, history, composer (or the read-only footer a
/// channel gets instead).
struct ConversationView: View {
    let summary: ChatSummary
    let repo: MessageRepo
    let fileStore: FileStore
    let shared: PanelSharedState
    let panelState: PanelState
    let mediaViewer: MediaViewerState
    var setPin: (PanelSharedState.PinReason, Bool) -> Void
    var onToggleMute: () -> Void

    @State private var isDropTargeted = false
    @State private var isNearBottom = true
    /// Where this open landed; drives the programmatic scroll after the
    /// initial history arrives. `.latest` after the FAB re-anchors to bottom.
    @State private var resolvedTarget: MessageRepo.OpenTarget = .latest
    /// The settle loop that keeps re-asserting the opening scroll until the
    /// viewport reports the target — see the `initialLoadGeneration` handler.
    @State private var openingScrollTask: Task<Void, Never>?
    /// This view instance's identity for visibility claims — see the
    /// `setConversationVisible` handlers below.
    @State private var visibilityToken = UUID()

    /// Sentinel row for programmatic scroll-to-bottom via `ScrollViewReader`.
    ///
    /// **Never bind a `ScrollPosition` to this list** (D38). On macOS 26 a
    /// `.scrollPosition(_:)` binding on a scroll view that is inside the
    /// panel's fold animation wedges SwiftUI's render loop for the whole
    /// process: bodies keep evaluating, but nothing paints ever again — every
    /// panel, every display, surviving even a full window rebuild. That is the
    /// founder's "phantom window" (state machine open, pixels frozen
    /// collapsed, clicks eaten by an invisible panel). Reproduced headlessly
    /// with `expand → openChat → collapse → expand`; verified gone with the
    /// binding removed and back with it restored.
    private static let bottomAnchorID = "conversation-bottom-anchor"

    private func sendFiles(_ urls: [URL]) {
        Task {
            for url in urls { await repo.sendFile(at: url) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            history
            footer
        }
        .background(Theme.Palette.chatCanvas)
        // Dictate keeps its HUD latched open while a dictation runs; the
        // equivalent here is an outgoing message still reaching the server —
        // a file mid-upload must not fold away when the pointer leaves. The
        // hold dies with this view: navigating away used to strand it (the
        // falling edge never fired) and latch the panel open forever.
        .onChange(of: repo.hasPendingOutgoing) { _, pending in
            setPin(.pendingOutgoing, pending)
        }
        .onAppear { setPin(.pendingOutgoing, repo.hasPendingOutgoing) }
        .onDisappear { setPin(.pendingOutgoing, false) }
        // Drop works because the expanded panel takes mouse events; while it is
        // collapsed `ignoresMouseEvents` is true and nothing can be dropped on
        // it — expanding first is the documented gesture.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in sendFiles([url]) }
                }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.Palette.accent, style: .init(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .task(id: summary.id) {
            // Deterministic open, no scroll memory: the first unread message
            // when there is one, else the bottom. Saved positions kept
            // resurfacing stale anchors ("teleported" opens), and Telegram's
            // own memory only matters for long reads — not worth the bugs at
            // this panel's scale.
            let target: MessageRepo.OpenTarget =
                summary.firstUnreadAnchor.map { .around($0) } ?? .latest
            resolvedTarget = target
            await repo.open(
                chatId: summary.id,
                target: target,
                unreadBoundary: summary.firstUnreadAnchor)
        }
        // Read receipts follow "the panel is settled on screen", not merely
        // "expanded": `forceRead` tells Telegram the messages were seen, and a
        // hover that brushes past an open chat should not claim that. Claims
        // carry this view's token: when the panel migrates to another screen,
        // the old screen's copy of this view unmounts *after* the new one has
        // settled, and its `onDisappear` must not revoke a visibility it no
        // longer owns — that was the "chat is open but never marks itself
        // read" bug.
        .onChange(of: panelState.settled) { _, settled in
            repo.setConversationVisible(settled, owner: visibilityToken)
        }
        .onAppear { repo.setConversationVisible(panelState.settled, owner: visibilityToken) }
        .onDisappear {
            repo.setConversationVisible(false, owner: visibilityToken)
            openingScrollTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AvatarView(summary: summary, fileStore: fileStore, diameter: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title)
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if !repo.typingNames.isEmpty {
                    HStack(spacing: 4) {
                        TypingDotsView()
                        Text(typingText)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .transition(.opacity)
                    .accessibilityIdentifier("typing-indicator")
                } else if summary.kind == .channel {
                    Text(L10n.s("channel", "канал"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 8)
        .background(Theme.Palette.surfaceRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Palette.separator).frame(height: 1)
        }
    }

    private var typingText: String {
        repo.typingNames.count == 1
            ? L10n.s("\(repo.typingNames[0]) is typing…", "\(repo.typingNames[0]) печатает…")
            : L10n.s(
                "\(repo.typingNames.count) people are typing…",
                "Печатают несколько человек…")
    }

    // MARK: - History

    private var history: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                historyScroll(width: proxy.size.width, scroller: scroller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("message-list")
    }

    private func historyScroll(width: CGFloat, scroller: ScrollViewProxy) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: Theme.Metrics.bubbleSpacing) {
                if repo.hasMoreHistory, !repo.items.isEmpty {
                    // Reaching the top pulls the next page; the repo
                    // rate-limits re-fires from re-materialisation.
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                        .onAppear { Task { await repo.loadOlder() } }
                }

                ForEach(rows) { row in
                    switch row {
                    case .day(let text, _):
                        ConversationSeparatorView(text: text)
                    case .service(_, let text):
                        ConversationSeparatorView(text: text)
                    case .unread:
                        UnreadDividerView()
                    case .message(let item, let context):
                        MessageBubbleView(
                            item: item,
                            fileStore: fileStore,
                            context: context,
                            maxWidth: width * Theme.Metrics.bubbleMaxWidthRatio,
                            onRetry: { Task { await repo.retry(item.id) } },
                            onOpenMedia: { messageId in
                                mediaViewer.present(items: repo.items, at: messageId)
                            },
                            onTranscribe: { messageId in
                                Task { await repo.transcribe(messageId: messageId) }
                            })
                            .padding(.top, context.isFirstInGroup ? Theme.Metrics.bubbleGroupSpacing : 0)
                            .onAppear { repo.noteVisible(item.messageId) }
                    case .album(let run, let context):
                        AlbumBubbleView(
                            items: run,
                            fileStore: fileStore,
                            context: context,
                            maxWidth: width * Theme.Metrics.bubbleMaxWidthRatio,
                            onOpenMedia: { messageId in
                                mediaViewer.present(items: repo.items, at: messageId)
                            })
                            .padding(.top, context.isFirstInGroup ? Theme.Metrics.bubbleGroupSpacing : 0)
                            .onAppear {
                                for item in run { repo.noteVisible(item.messageId) }
                            }
                    }
                }

                if repo.hasMoreNewer {
                    // The window slid off the live bottom during deep
                    // scroll-back; reaching this edge pages the gap back in.
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                        .onAppear { Task { await repo.loadNewer() } }
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.vertical, 8)
        }
        .scrollContentBackground(.hidden)
        // A chat opens at its newest message, and rows under the reader's
        // eyes stay put while history pages land — without a `ScrollPosition`
        // binding (see `bottomAnchorID`), size-change anchoring stands in for
        // its identity tracking. Bottom-anchored while the window holds the
        // live bottom (glues the reader to new messages, and keeps their
        // place while older pages prepend above); top-anchored only while
        // detached (paging the gap downward must not shift the view). A
        // first cut keyed this on the last page's *direction* — which flips
        // to .newer on every live message and silently killed follow-to-
        // bottom, the founder's "it doesn't stick to the bottom".
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(repo.hasMoreNewer ? .top : .bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 60
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        .onChange(of: repo.initialLoadGeneration) { _, _ in
            // A closed loop, not one blind scrollTo. The generation bump lands
            // in the same transaction as the merged rows, so a single scroll
            // targets geometry that has not laid out yet; LazyVStack's
            // estimated row heights then drift the viewport as real heights
            // and late pages land. One-shot scrolls left the founder's two
            // opening bugs: a viewport stranded outside the content (blank
            // chat until a wheel wiggle re-clamps) and opens "teleported"
            // mid-history. Re-assert every 150 ms until the viewport actually
            // reports the target, bounded so a user scroll is never fought
            // for longer than the settle window.
            openingScrollTask?.cancel()
            performOpeningScroll(scroller)
            openingScrollTask = Task { @MainActor in
                for tick in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    performOpeningScroll(scroller)
                    guard !repo.isLoadingHistory else { continue }
                    switch resolvedTarget {
                    case .latest where isNearBottom && tick >= 1: return
                    case .around where tick >= 2: return
                    default: continue
                    }
                }
            }
        }
        .onChange(of: repo.items.last?.id) { _, last in
            guard !repo.hasMoreNewer else { return }
            // Your own send always lands you at the bottom (Telegram's rule);
            // incoming messages follow only while the reader is already
            // there — never yank them out of history.
            let isOwnSend = repo.items.last?.isOutgoing == true && last != nil
            guard isOwnSend || isNearBottom else { return }
            // Glued to the bottom, the arriving message is on screen by
            // definition — note it without waiting for the lazy row's
            // `onAppear`, which is not guaranteed to re-fire mid-scroll.
            if let newest = repo.items.last, !newest.isOutgoing {
                repo.noteVisible(newest.messageId)
            }
            withAnimation(.easeOut(duration: 0.2)) {
                scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isNearBottom || repo.hasMoreNewer {
                scrollToBottomButton(scroller)
            }
        }
    }

    /// The programmatic scroll per open, fired when the initial history
    /// lands: to the unread divider, or to the bottom.
    private func performOpeningScroll(_ scroller: ScrollViewProxy) {
        switch resolvedTarget {
        case .latest:
            scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        case .around(let anchor):
            if let boundary = repo.unreadBoundary, boundary == anchor,
               rows.contains(where: { $0.id == .unread }) {
                // The divider sits in the upper third, Telegram's placement.
                scroller.scrollTo(Row.RowID.unread, anchor: UnitPoint(x: 0.5, y: 0.2))
            } else if let item = repo.items.first(where: { $0.messageId >= anchor }) {
                scroller.scrollTo(Row.RowID.message(item.id), anchor: .top)
            } else {
                scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottomButton(_ scroller: ScrollViewProxy) -> some View {
        Button {
            if repo.hasMoreNewer {
                // The loaded bottom is not the live bottom — jump means
                // re-anchoring the window at the newest page, like Telegram.
                // The reload's generation bump lands the scroll (resolved to
                // .latest here so the opening-scroll goes to the bottom).
                resolvedTarget = .latest
                Task { await repo.reloadLatest() }
            }
            withAnimation(.easeOut(duration: 0.25)) {
                scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } label: {
            // The one true Liquid Glass island in the conversation: it floats
            // over scrolling content, so the live material earns its keep.
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .glassIsland(in: .circle, interactive: true)
        }
        .buttonStyle(.pressable)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .accessibilityIdentifier("scroll-to-bottom")
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if summary.canSendMessages {
            ComposerView(
                chatId: summary.id,
                shared: shared,
                onSend: { text in Task { await repo.sendText(text) } },
                onSendFiles: sendFiles,
                setPin: setPin)
        } else if summary.kind == .channel {
            // Telegram's channel footer: no input, one mute toggle.
            Button(action: onToggleMute) {
                Text(summary.isMuted
                    ? L10n.s("Unmute", "Включить уведомления")
                    : L10n.s("Mute", "Отключить уведомления"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(Theme.Palette.surfaceRaised)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.Palette.separator).frame(height: 1)
            }
            .accessibilityIdentifier("channel-footer")
        } else {
            Text(L10n.s("Posting is restricted here", "Отправка сообщений запрещена"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.Palette.surfaceRaised)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.Palette.separator).frame(height: 1)
                }
                .accessibilityIdentifier("restricted-footer")
        }
    }

    // MARK: - Rows

    enum Row: Identifiable {
        case day(String, id: String)
        case message(MessageItem, MessageRowContext)
        /// A `media_album_id` run rendered as one Telegram-style mosaic post.
        case album([MessageItem], MessageRowContext)
        case service(MessageKey, String)
        /// The "Unread messages" divider — at most one per open.
        case unread

        var id: RowID {
            switch self {
            case .day(_, let id): .day(id)
            case .message(let item, _): .message(item.id)
            case .album(let items, _): .album(items[0].id)
            case .service(let key, _): .service(key)
            case .unread: .unread
            }
        }

        enum RowID: Hashable {
            case day(String)
            case message(MessageKey)
            case album(MessageKey)
            case service(MessageKey)
            case unread
        }
    }

    /// One visual turn: a lone message, or an album run collapsed into one.
    enum Unit {
        case single(MessageItem)
        case album([MessageItem])

        var first: MessageItem {
            switch self {
            case .single(let item): item
            case .album(let items): items[0]
            }
        }

        var last: MessageItem {
            switch self {
            case .single(let item): item
            case .album(let items): items[items.count - 1]
            }
        }
    }

    /// Only photos and videos join a mosaic; Telegram renders grouped
    /// documents/audio as stacked ordinary bubbles. (Takes the item, not the
    /// content: Features files stay free of TDLibKit imports — the enum's
    /// type is inferred from `item.content`.)
    static func isAlbumEligible(_ item: MessageItem) -> Bool {
        switch item.content {
        case .messagePhoto, .messageVideo: true
        default: false
        }
    }

    /// Collapses consecutive same-`mediaAlbumId` photo/video messages into
    /// album units. Static and internal for the unit tests.
    static func units(from items: [MessageItem]) -> [Unit] {
        var result: [Unit] = []
        result.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            let item = items[index]
            if item.mediaAlbumId != 0, isAlbumEligible(item) {
                var run = [item]
                var next = index + 1
                while next < items.count,
                      items[next].mediaAlbumId == item.mediaAlbumId,
                      isAlbumEligible(items[next]) {
                    run.append(items[next])
                    next += 1
                }
                if run.count > 1 {
                    result.append(.album(run))
                    index = next
                    continue
                }
            }
            result.append(.single(item))
            index += 1
        }
        return result
    }

    /// Two messages this close, from one sender, read as one turn.
    private static let groupingWindow = 600

    /// Interleaves date separators and computes run positions — the sender name
    /// shows at a run's first message, the avatar at its last, and the corners
    /// tighten in between, which is what makes a conversation read as turns.
    private var rows: [Row] {
        let showsAvatars = summary.kind == .basicGroup || summary.kind == .supergroup
        let units = Self.units(from: repo.items)
        var result: [Row] = []
        result.reserveCapacity(units.count + 8)
        // The boundary captured at open — updates from this visit's own read
        // receipts must not move the divider mid-read.
        let boundary = repo.unreadBoundary
        var dividerPlaced = false
        // Built on the first reply only — most windows have none.
        var replyIndex: [Int64: MessageItem]?

        for (index, unit) in units.enumerated() {
            let item = unit.first
            if let boundary, !dividerPlaced, !item.isOutgoing,
               item.messageId > boundary {
                result.append(.unread)
                dividerPlaced = true
            }
            let day = Self.dayLabel(item.date)
            let previous = index > 0 ? units[index - 1].last : nil
            let next = index < units.count - 1 ? units[index + 1].first : nil

            let newDay = previous.map { Self.dayLabel($0.date) != day } ?? true
            if newDay {
                result.append(.day(day, id: day))
            }
            if item.isService {
                result.append(.service(item.id, MessagePreview.text(
                    for: item.content, language: .system)))
                continue
            }

            let chainsFromPrevious = !newDay && previous.map {
                !$0.isService && $0.senderUserId == item.senderUserId
                    && $0.isOutgoing == item.isOutgoing
                    && item.date - $0.date < Self.groupingWindow
            } ?? false
            let chainsToNext = next.map {
                !$0.isService && $0.senderUserId == item.senderUserId
                    && $0.isOutgoing == item.isOutgoing
                    && $0.date - item.date < Self.groupingWindow
                    && Self.dayLabel($0.date) == day
            } ?? false

            let context = MessageRowContext(
                isFirstInGroup: !chainsFromPrevious,
                isLastInGroup: !chainsToNext,
                showsSender: !chainsFromPrevious && !item.isOutgoing
                    && showsAvatars && !item.senderName.isEmpty,
                showsAvatar: showsAvatars && !item.isOutgoing,
                senderPhotoFileId: showsAvatars && !item.isOutgoing
                    ? repo.photoFileId(forUser: item.senderUserId)
                    : nil,
                reply: item.replyToMessageId.flatMap { replyId in
                    Self.replyQuote(for: replyId, in: repo.items, indexed: &replyIndex)
                })
            switch unit {
            case .single:
                result.append(.message(item, context))
            case .album(let run):
                result.append(.album(run, context))
            }
        }
        return result
    }

    /// The quote a reply draws, resolved against the loaded window. A target
    /// outside the window (scrolled off, or never loaded) draws no quote
    /// rather than a placeholder. Static and internal for the unit tests.
    static func replyQuote(
        for messageId: Int64,
        in items: [MessageItem],
        indexed index: inout [Int64: MessageItem]?
    ) -> ReplyQuote? {
        if index == nil {
            index = Dictionary(
                items.filter { $0.messageId != 0 }.map { ($0.messageId, $0) },
                uniquingKeysWith: { first, _ in first })
        }
        guard let target = index?[messageId] else { return nil }
        let name = target.isOutgoing ? L10n.s("You", "Вы") : target.senderName
        return ReplyQuote(
            senderName: name.isEmpty ? L10n.s("Message", "Сообщение") : name,
            senderUserId: target.senderUserId,
            isOutgoing: target.isOutgoing,
            text: MessagePreview.text(for: target.content, language: .system)
                .replacingOccurrences(of: "\n", with: " "))
    }

    // MARK: - Dates

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.dateLocale
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    private static let otherYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.dateLocale
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static func dayLabel(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.s("Today", "Сегодня") }
        if calendar.isDateInYesterday(date) { return L10n.s("Yesterday", "Вчера") }
        return calendar.isDate(date, equalTo: Date(), toGranularity: .year)
            ? sameYearFormatter.string(from: date)
            : otherYearFormatter.string(from: date)
    }
}
