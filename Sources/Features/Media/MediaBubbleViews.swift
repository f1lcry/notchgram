// AVFoundation, not AVKit: SwiftUI's VideoPlayer (AVKit_SwiftUI) aborts the
// process on macOS 26.6 — see PlayerLayerView.
import AVFoundation
import AppKit
import SwiftUI

/// Dispatches a message's media to the right renderer, or falls back to a
/// readable line. Every branch here is a measured fact, not a guess — see
/// `MediaDescriptor`.
struct MediaContentView: View {
    let item: MessageItem
    let fileStore: FileStore
    let maxWidth: CGFloat
    /// Photos and videos open in the in-panel viewer (C5); the closure gets
    /// the message id to anchor the gallery.
    var onOpenMedia: (Int64) -> Void = { _ in }
    /// Voice/video notes route their Telegram transcription request (C6).
    var onTranscribe: (Int64) -> Void = { _ in }

    var body: some View {
        switch MediaDescriptor.from(item.content) {
        case .photo(let photo):
            PhotoBubbleView(
                photo: photo, fileStore: fileStore, maxWidth: maxWidth,
                onOpen: { onOpenMedia(item.messageId) })
        case .sticker(let sticker):
            StickerBubbleView(sticker: sticker, fileStore: fileStore)
        case .animation(let animation):
            AnimationBubbleView(animation: animation, fileStore: fileStore, maxWidth: maxWidth)
        case .voice(let voice):
            VoiceNoteBubbleView(
                voice: voice, fileStore: fileStore,
                onTranscribe: { onTranscribe(item.messageId) })
        case .video(let video):
            VideoBubbleView(
                video: video, fileStore: fileStore, maxWidth: maxWidth,
                onOpen: { onOpenMedia(item.messageId) })
        case .videoNote(let note):
            VideoNoteCircleView(
                note: note, fileStore: fileStore,
                onTranscribe: { onTranscribe(item.messageId) })
        case .document(let document):
            DocumentBubbleView(document: document, fileStore: fileStore)
        case nil:
            Text(MessagePreview.text(for: item.content, language: .system))
                .font(Theme.Fonts.messageBody)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}

/// Blurred inline preview drawn while (or instead of) the real file. Cached —
/// decoding the Data per body pass was one of Session 1's slow paths.
/// Internal: the album mosaic and the media viewer draw it too.
struct MinithumbImage: View {
    let data: Data?
    var blur: CGFloat = 6
    /// `.fill` for bubbles/cells; the viewer uses `.fit` — a cropped stand-in
    /// there reads as "the photo is zoomed in and cut off".
    var contentMode: ContentMode = .fill

    var body: some View {
        if let data, let image = MinithumbCache.image(for: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .blur(radius: blur)
        }
    }
}

private struct MediaCaption: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Theme.Fonts.messageBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Photo

struct PhotoBubbleView: View {
    let photo: PhotoDescriptor
    let fileStore: FileStore
    let maxWidth: CGFloat
    /// Opens the in-panel viewer. Falling back to nothing would strand the
    /// user, so the default opens the downloaded file externally.
    var onOpen: (() -> Void)?

    @Environment(\.displayScale) private var scale

    private var target: (fileId: Int, width: Int, height: Int)? {
        photo.bestSize(forWidth: min(maxWidth, 320), scale: scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { onOpen?() ?? openExternally() }) {
                ZStack {
                    // The inline minithumbnail is drawn on the first frame, so a
                    // photo is never an empty grey rectangle waiting on a download.
                    MinithumbImage(data: photo.minithumbnail)
                    MediaImage(url: localURL, targetSize: displaySize) {
                        if progress != nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            MediaCaption(text: photo.caption)
        }
        .onAppear { if let target { fileStore.requestDownload(target.fileId) } }
        .accessibilityIdentifier("media-photo")
    }

    private var displaySize: CGSize {
        let width = min(maxWidth, 320)
        return CGSize(width: width, height: (width / max(photo.aspectRatio, 0.3)).rounded())
    }

    /// Non-nil only when the download is complete: TDLib warns that bytes on
    /// disk may be garbage before that, and a partial JPEG draws as noise.
    private var localURL: URL? {
        target.flatMap { fileStore.localURL(for: $0.fileId) }
    }

    private var progress: Double? {
        target.flatMap { fileStore.state(for: $0.fileId)?.downloadProgress }
    }

    private func openExternally() {
        guard let localURL else { return }
        NSWorkspace.shared.open(localURL)
    }
}

// MARK: - Sticker

struct StickerBubbleView: View {
    let sticker: StickerDescriptor
    let fileStore: FileStore

    var body: some View {
        MediaImage(url: renderableURL, targetSize: size, contentMode: .fit) {
            // tgs (gzipped Lottie) and webm (no matroska UTI on macOS 26)
            // cannot be drawn here, and neither can one still downloading —
            // the emoji is what Telegram itself shows in that case.
            Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji)
                .font(.system(size: 40))
        }
        .frame(width: size.width, height: size.height)
        .onAppear(perform: request)
        .accessibilityIdentifier("media-sticker-\(sticker.format.rawValue)")
    }

    private var size: CGSize {
        let side: CGFloat = 120
        let ratio = sticker.height > 0 ? CGFloat(sticker.width) / CGFloat(sticker.height) : 1
        return ratio >= 1
            ? CGSize(width: side, height: side / ratio)
            : CGSize(width: side * ratio, height: side)
    }

    private func request() {
        // Only webp is worth fetching for display; for the other two the
        // thumbnail is the renderable artefact.
        if sticker.isRenderable {
            fileStore.requestDownload(sticker.fileId)
        } else if let thumbnail = sticker.thumbnailFileId {
            fileStore.requestDownload(thumbnail)
        }
    }

    private var renderableURL: URL? {
        if sticker.isRenderable, let url = fileStore.localURL(for: sticker.fileId) {
            // webp decodes natively: org.webmproject.webp is a registered
            // ImageIO type on macOS 26.
            return url
        }
        if let thumbnail = sticker.thumbnailFileId {
            return fileStore.localURL(for: thumbnail)
        }
        return nil
    }
}

// MARK: - Animation (GIF)

/// Hard cap on concurrent inline AVPlayers. A fast scroll through a GIF-heavy
/// chat used to create/destroy an `AVQueuePlayer` + `AVPlayerLooper` per
/// bubble at scroll speed with no bound — one of the fast-scroll crash
/// vectors. Bubbles that miss the budget show their thumbnail; the budget
/// frees as playing bubbles scroll off.
@MainActor
enum InlinePlayerBudget {
    static let limit = 4
    private(set) static var active = 0

    static func acquire() -> Bool {
        guard active < limit else { return false }
        active += 1
        return true
    }

    static func release() {
        active = max(0, active - 1)
    }
}

struct AnimationBubbleView: View {
    let animation: AnimationDescriptor
    let fileStore: FileStore
    let maxWidth: CGFloat

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                MinithumbImage(data: animation.minithumbnail, blur: 4)
                if let player {
                    PlayerLayerView(player: player)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("GIF")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.45), in: .capsule)
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .clipShape(.rect(cornerRadius: 8))

            MediaCaption(text: animation.caption)
        }
        .onAppear {
            fileStore.requestDownload(animation.fileId)
            startIfReady()
        }
        .onChange(of: fileStore.state(for: animation.fileId)?.isDownloaded ?? false) { _, _ in
            startIfReady()
        }
        .onDisappear {
            if player != nil { InlinePlayerBudget.release() }
            player?.pause()
            player = nil
            looper = nil
        }
        .accessibilityIdentifier("media-animation")
    }

    private var displaySize: CGSize {
        let width = min(maxWidth, 260)
        let ratio = animation.height > 0
            ? CGFloat(animation.width) / CGFloat(animation.height)
            : 1
        return CGSize(width: width, height: (width / max(ratio, 0.3)).rounded())
    }

    /// Telegram sends most "GIFs" as silent mp4, so this branches on the mime
    /// type rather than the name. A true image/gif is drawn as a still: AppKit
    /// animates GIFs only through NSImageView, which is not worth a bridge for
    /// the rare case.
    private func startIfReady() {
        guard player == nil,
              animation.isVideoContainer,
              let url = fileStore.localURL(for: animation.fileId),
              InlinePlayerBudget.acquire()
        else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        player = queue
    }
}

// MARK: - Video

struct VideoBubbleView: View {
    let video: VideoDescriptor
    let fileStore: FileStore
    let maxWidth: CGFloat
    /// Opens the in-panel viewer, which downloads and plays inside the panel.
    var onOpen: (() -> Void)?

    /// External-open fallback path only (no in-panel viewer wired).
    @State private var opensWhenDownloaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A `Button`, not `.onTapGesture`: inside a scrolling message list
            // a tap gesture never fires on macOS.
            Button(action: { onOpen?() ?? openOrDownload() }) {
                ZStack {
                    MinithumbImage(data: video.minithumbnail, blur: 4)
                    if let thumbnailId = video.thumbnailFileId {
                        MediaImage(
                            url: fileStore.localURL(for: thumbnailId),
                            targetSize: displaySize
                        ) { Color.clear }
                    }
                    badge
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .clipShape(.rect(cornerRadius: 8))
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            MediaCaption(text: video.caption)
        }
        .onAppear {
            // The thumbnail only. A full video is megabytes, and it opens in
            // the system player rather than an embedded one.
            if let thumbnailId = video.thumbnailFileId {
                fileStore.requestDownload(thumbnailId, priority: 8)
            }
        }
        .onChange(of: fileStore.state(for: video.fileId)?.isDownloaded ?? false) { _, downloaded in
            guard downloaded, opensWhenDownloaded,
                  let url = fileStore.localURL(for: video.fileId) else { return }
            opensWhenDownloaded = false
            NSWorkspace.shared.open(url)
        }
        .accessibilityIdentifier("media-video")
    }

    @ViewBuilder
    private var badge: some View {
        let state = fileStore.state(for: video.fileId)
        HStack(spacing: 4) {
            if let progress = state?.downloadProgress, state?.isDownloading == true {
                ProgressView().controlSize(.mini)
                Text("\(Int(progress * 100)) %")
                    .monospacedDigit()
            } else {
                Image(systemName: state?.isDownloaded == true ? "play.fill" : "arrow.down.to.line")
                Text(formatDuration(video.duration))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: .capsule)
    }

    private var displaySize: CGSize {
        let width = min(maxWidth, 280)
        let ratio = video.height > 0 ? CGFloat(video.width) / CGFloat(video.height) : 1.6
        return CGSize(width: width, height: (width / max(ratio, 0.3)).rounded())
    }

    private func openOrDownload() {
        if let url = fileStore.localURL(for: video.fileId) {
            NSWorkspace.shared.open(url)
        } else {
            opensWhenDownloaded = true
            fileStore.requestDownload(video.fileId, priority: 32)
        }
    }
}

// MARK: - Video note (round message)

/// Round messages play **inline, in the circle, with sound** — Telegram's
/// behavior. Session 4 downloaded the file and opened Preview.app, which the
/// founder called out as exactly wrong (C6). Click toggles play/pause; a
/// finished note replays from the start.
struct VideoNoteCircleView: View {
    let note: VideoNoteDescriptor
    let fileStore: FileStore
    var onTranscribe: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playsWhenDownloaded = false

    private static let diameter: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                circle
                if let onTranscribe, showsTranscribeButton {
                    TranscribeButton(action: onTranscribe)
                }
            }
            TranscriptView(state: note.transcript)
        }
        .onAppear {
            if let thumbnailId = note.thumbnailFileId {
                fileStore.requestDownload(thumbnailId, priority: 8)
            }
        }
        .onChange(of: fileStore.state(for: note.fileId)?.isDownloaded ?? false) { _, downloaded in
            guard downloaded, playsWhenDownloaded,
                  let url = fileStore.localURL(for: note.fileId) else { return }
            playsWhenDownloaded = false
            start(url)
        }
        .onDisappear {
            player?.pause()
            player = nil
            isPlaying = false
        }
        .accessibilityIdentifier("media-video-note")
    }

    private var circle: some View {
        Button(action: toggle) {
            ZStack {
                Circle().fill(Theme.Palette.bubbleIn)
                MinithumbImage(data: note.minithumbnail, blur: 4)
                if player == nil, let thumbnailId = note.thumbnailFileId {
                    MediaImage(
                        url: fileStore.localURL(for: thumbnailId),
                        targetSize: CGSize(width: Self.diameter, height: Self.diameter)
                    ) { Color.clear }
                }
                if let player {
                    PlayerLayerView(player: player)
                }
                if !isPlaying { badge }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var showsTranscribeButton: Bool {
        switch note.transcript {
        case .none, .failed: true
        case .pending, .done: false
        }
    }

    @ViewBuilder
    private var badge: some View {
        let state = fileStore.state(for: note.fileId)
        VStack {
            Spacer()
            HStack(spacing: 4) {
                if let progress = state?.downloadProgress, state?.isDownloading == true {
                    ProgressView().controlSize(.mini)
                    Text("\(Int(progress * 100)) %").monospacedDigit()
                } else {
                    Image(systemName: "play.fill")
                    Text(formatDuration(note.duration)).monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(.bottom, 10)
        }
    }

    private func toggle() {
        if let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                // A finished note replays; CMTime math guards the not-yet-
                // loaded duration.
                if let item = player.currentItem, item.duration.isNumeric,
                   CMTimeCompare(item.currentTime(), item.duration) >= 0 {
                    player.seek(to: .zero)
                }
                player.play()
                isPlaying = true
            }
            return
        }
        if let url = fileStore.localURL(for: note.fileId) {
            start(url)
        } else {
            playsWhenDownloaded = true
            fileStore.requestDownload(note.fileId, priority: 32)
        }
    }

    private func start(_ url: URL) {
        let fresh = AVPlayer(url: url)
        player = fresh
        fresh.play()
        isPlaying = true
    }
}

// MARK: - Document

struct DocumentBubbleView: View {
    let document: DocumentDescriptor
    let fileStore: FileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: openOrDownload) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Theme.Palette.accentMuted).frame(width: 32, height: 32)
                        if state?.isDownloading == true {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: state?.isDownloaded == true ? "doc.fill" : "arrow.down")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.fileName.isEmpty ? L10n.s("File", "Файл") : document.fileName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(formatFileSize(document.size))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .monospacedDigit()
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            MediaCaption(text: document.caption)
        }
        .accessibilityIdentifier("media-document")
    }

    private var state: FileState? { fileStore.state(for: document.fileId) }

    private func openOrDownload() {
        if let url = fileStore.localURL(for: document.fileId) {
            NSWorkspace.shared.open(url)
        } else {
            fileStore.requestDownload(document.fileId, priority: 32)
        }
    }
}
