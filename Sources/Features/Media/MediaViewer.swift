import AVFoundation
import AppKit
import SwiftUI

/// One entry in the in-panel media gallery.
struct MediaViewerEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case photo(PhotoDescriptor)
        case video(VideoDescriptor)
    }

    /// The message id — unique within the chat the gallery was built from.
    let id: Int64
    let kind: Kind
}

/// The in-panel media viewer (C5): photos and videos open inside the panel,
/// not in Preview.app. The gallery is the loaded window's media, newest last;
/// chevrons/arrow keys step through it.
@MainActor
@Observable
final class MediaViewerState {
    private(set) var entries: [MediaViewerEntry] = []
    private(set) var index = 0
    private(set) var isPresented = false

    var current: MediaViewerEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    var canStepBack: Bool { index > 0 }
    var canStepForward: Bool { index < entries.count - 1 }

    /// Opens the gallery at the clicked message. Items that are not photo or
    /// video are skipped — they have their own presentations.
    func present(items: [MessageItem], at messageId: Int64) {
        let gallery = items.compactMap { item -> MediaViewerEntry? in
            switch MediaDescriptor.from(item.content) {
            case .photo(let photo):
                MediaViewerEntry(id: item.messageId, kind: .photo(photo))
            case .video(let video):
                MediaViewerEntry(id: item.messageId, kind: .video(video))
            default:
                nil
            }
        }
        guard let start = gallery.firstIndex(where: { $0.id == messageId }) else { return }
        entries = gallery
        index = start
        isPresented = true
    }

    func close() {
        isPresented = false
        entries = []
        index = 0
    }

    func step(_ delta: Int) {
        index = max(0, min(entries.count - 1, index + delta))
    }
}

/// The overlay itself: dark scrim, the media fitted inside, chevrons, counter,
/// close. Esc routes here first (AppDelegate's step-back chain).
struct MediaViewerView: View {
    let viewer: MediaViewerState
    let fileStore: FileStore
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .contentShape(.rect)
                .onTapGesture { viewer.close() }

            if let entry = viewer.current {
                content(entry)
                    .id(entry.id)
                    .padding(.horizontal, 46)
                    .padding(.top, 40)
                    .padding(.bottom, 16)
            }

            chrome
        }
        .onAppear { setPin(.mediaViewer, true) }
        .onDisappear { setPin(.mediaViewer, false) }
        .transition(.opacity)
        .accessibilityIdentifier("media-viewer")
    }

    @ViewBuilder
    private func content(_ entry: MediaViewerEntry) -> some View {
        switch entry.kind {
        case .photo(let photo):
            ViewerPhotoView(photo: photo, fileStore: fileStore)
        case .video(let video):
            ViewerVideoView(video: video, fileStore: fileStore)
        }
    }

    private var chrome: some View {
        ZStack {
            VStack {
                HStack {
                    if viewer.entries.count > 1 {
                        Text("\(viewer.index + 1) / \(viewer.entries.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .monospacedDigit()
                    }
                    Spacer()
                    chromeButton("xmark", identifier: "viewer-close") { viewer.close() }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer()
            }

            HStack {
                if viewer.canStepBack {
                    chromeButton("chevron.left", identifier: "viewer-prev") { viewer.step(-1) }
                }
                Spacer()
                if viewer.canStepForward {
                    chromeButton("chevron.right", identifier: "viewer-next") { viewer.step(1) }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func chromeButton(
        _ symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Liquid Glass earns its keep here: the chrome floats over the
            // photo itself, and the material refracts it.
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
                .glassIsland(in: .circle, interactive: true)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(identifier)
    }
}

/// Full photo, always letterboxed — never cropped. While the largest size
/// downloads, the largest size already on disk (usually the bubble's) shows
/// fitted; the blurred minithumbnail also fits, so a portrait never reads as
/// "zoomed in with the top and bottom cut off" (the founder's exact
/// complaint on the first build of this viewer).
private struct ViewerPhotoView: View {
    let photo: PhotoDescriptor
    let fileStore: FileStore

    @State private var zoomed = false

    private var fullFileId: Int? { photo.sizes.last?.fileId }

    /// The largest size that is already on disk — progressive display: it
    /// switches to the full file the moment that lands.
    private var bestLocalURL: URL? {
        for size in photo.sizes.reversed() {
            if let url = fileStore.localURL(for: size.fileId) { return url }
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MinithumbImage(data: photo.minithumbnail, blur: 8, contentMode: .fit)
                MediaImage(
                    url: bestLocalURL,
                    targetSize: proxy.size,
                    contentMode: .fit
                ) {
                    if let fullFileId,
                       let progress = fileStore.state(for: fullFileId)?.downloadProgress {
                        ProgressView(value: progress).frame(width: 120)
                    } else {
                        ProgressView()
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .scaleEffect(zoomed ? 2 : 1)
            .animation(.easeOut(duration: 0.18), value: zoomed)
            .contentShape(.rect)
            .onTapGesture(count: 2) { zoomed.toggle() }
        }
        .onAppear {
            if let fullFileId { fileStore.requestDownload(fullFileId, priority: 32) }
        }
        .accessibilityIdentifier("viewer-photo")
    }
}

/// Video playback inside the panel: downloads if needed, then plays through a
/// bare AVPlayerLayer (never SwiftUI's VideoPlayer — see PlayerLayerView).
private struct ViewerVideoView: View {
    let video: VideoDescriptor
    let fileStore: FileStore

    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            MinithumbImage(data: video.minithumbnail, blur: 8)
            if let thumbnailId = video.thumbnailFileId, player == nil {
                MediaImage(
                    url: fileStore.localURL(for: thumbnailId),
                    targetSize: CGSize(width: 800, height: 600),
                    contentMode: .fit
                ) { Color.clear }
            }
            if let player {
                PlayerLayerView(player: player, gravity: .resizeAspect)
            } else if let progress = fileStore.state(for: video.fileId)?.downloadProgress,
                      fileStore.state(for: video.fileId)?.isDownloading == true {
                ProgressView(value: progress).frame(width: 120)
            }

            controls
        }
        .onAppear {
            fileStore.requestDownload(video.fileId, priority: 32)
            if let thumbnailId = video.thumbnailFileId {
                fileStore.requestDownload(thumbnailId, priority: 16)
            }
            startIfReady()
        }
        .onChange(of: fileStore.state(for: video.fileId)?.isDownloaded ?? false) { _, _ in
            startIfReady()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .accessibilityIdentifier("viewer-video")
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    guard let player else { return }
                    if isPlaying { player.pause() } else { player.play() }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.55), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(player == nil)
                .accessibilityIdentifier("viewer-play-pause")
                Spacer()
                Text(formatDuration(video.duration))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func startIfReady() {
        guard player == nil, let url = fileStore.localURL(for: video.fileId) else { return }
        let fresh = AVPlayer(url: url)
        player = fresh
        fresh.play()
        isPlaying = true
    }
}
