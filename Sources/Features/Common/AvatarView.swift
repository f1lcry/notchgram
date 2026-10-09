import AppKit
import SwiftUI

/// Chat avatar: minithumbnail first, real photo when it lands, monogram when
/// there is neither.
///
/// The minithumbnail matters more than it looks. TDLib ships a handful of inline
/// JPEG bytes with the chat itself, so the list can be fully drawn on the first
/// frame; without it a cold start shows a column of grey circles that fill in
/// one network round trip later, which is the single most obvious way a client
/// reads as slow.
///
/// All decodes go through the caches: Session 1 re-read the photo from disk on
/// every body pass of every row, which multiplied across a 40-row list into a
/// measurable slice of the main thread.
struct AvatarView: View {
    let summary: ChatSummary
    let fileStore: FileStore
    var diameter: CGFloat = Theme.Metrics.chatRowAvatar

    var body: some View {
        ZStack {
            Circle().fill(Theme.Palette.avatarColor(for: summary.id))

            if summary.kind == .savedMessages {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: diameter * 0.4))
                    .foregroundStyle(.white)
            } else {
                Text(summary.initials)
                    .font(.system(size: diameter * 0.36, weight: .medium))
                    .foregroundStyle(.white)

                if let thumb = summary.minithumbnail.flatMap(MinithumbCache.image(for:)) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        // The minithumbnail is a few dozen pixels wide; scaled
                        // up it is blocky rather than soft without this.
                        .blur(radius: 2)
                }
                MediaImage(
                    url: photoURL,
                    targetSize: CGSize(width: diameter, height: diameter)
                ) { Color.clear }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .onAppear(perform: requestPhoto)
        .onChange(of: summary.photoFileId) { _, _ in requestPhoto() }
    }

    private var photoURL: URL? {
        summary.photoFileId.flatMap { fileStore.localURL(for: $0) }
    }

    private func requestPhoto() {
        guard let fileId = summary.photoFileId else { return }
        fileStore.requestDownload(fileId, priority: 8)
    }
}
