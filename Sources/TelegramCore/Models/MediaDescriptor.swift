import Foundation
@preconcurrency import TDLibKit

/// What a media bubble needs, pulled out of `MessageContent` once.
///
/// The decode facts encoded here were measured on this machine, not assumed:
///
/// - **webp stickers decode natively** — `org.webmproject.webp` is a registered
///   ImageIO type on macOS 26, so `NSImage(contentsOf:)` opens them.
/// - **`stickerFormatWebm` is unplayable**: AVFoundation ships no webm/matroska
///   UTI on 26.6, so an animated webm sticker must fall back to its thumbnail
///   rather than to an AVPlayer that will silently show nothing.
/// - **TGS is gzipped Lottie** and needs a renderer nobody has written here; it
///   also falls back to the thumbnail (T3).
/// - **GIFs from Telegram are usually `video/mp4`**, not GIF data, so the
///   renderer must branch on `mimeType` instead of trusting the name.
public enum MediaDescriptor: Equatable, Sendable {
    case photo(PhotoDescriptor)
    case sticker(StickerDescriptor)
    case animation(AnimationDescriptor)
    case voice(VoiceDescriptor)
    case video(VideoDescriptor)
    case videoNote(VideoNoteDescriptor)
    case document(DocumentDescriptor)

    public static func from(_ content: MessageContent) -> MediaDescriptor? {
        switch content {
        case .messagePhoto(let value):
            return .photo(PhotoDescriptor(value.photo, caption: value.caption.text))
        case .messageSticker(let value):
            return .sticker(StickerDescriptor(value.sticker))
        case .messageAnimation(let value):
            return .animation(AnimationDescriptor(value.animation, caption: value.caption.text))
        case .messageVoiceNote(let value):
            return .voice(VoiceDescriptor(value.voiceNote, isListened: value.isListened))
        case .messageVideo(let value):
            return .video(VideoDescriptor(value.video, caption: value.caption.text))
        case .messageVideoNote(let value):
            return .videoNote(VideoNoteDescriptor(value.videoNote))
        case .messageDocument(let value):
            return .document(DocumentDescriptor(value.document, caption: value.caption.text))
        default:
            return nil
        }
    }
}

/// Telegram's server-side speech recognition state for a voice/video note
/// (`recognizeSpeech` → `speech_recognition_result`). Premium-gated with a
/// weekly free trial; the error carries Telegram's own message.
public enum TranscriptState: Equatable, Sendable {
    case none
    case pending(String)
    case done(String)
    case failed(String)

    init(_ result: SpeechRecognitionResult?) {
        switch result {
        case nil:
            self = .none
        case .speechRecognitionResultPending(let value):
            self = .pending(value.partialText)
        case .speechRecognitionResultText(let value):
            self = .done(value.text)
        case .speechRecognitionResultError(let value):
            self = .failed(value.error.message)
        }
    }
}

/// A round video message. Plays inline inside its circle (C6).
public struct VideoNoteDescriptor: Equatable, Sendable {
    public var fileId: Int
    public var thumbnailFileId: Int?
    public var minithumbnail: Data?
    public var duration: Int
    public var transcript: TranscriptState

    init(_ note: VideoNote) {
        fileId = note.video.id
        thumbnailFileId = note.thumbnail?.file.id
        minithumbnail = note.minithumbnail?.data
        duration = note.duration
        transcript = TranscriptState(note.speechRecognitionResult)
    }
}

public struct PhotoDescriptor: Equatable, Sendable {
    /// Smallest first, as TDLib orders them.
    public var sizes: [(fileId: Int, width: Int, height: Int)]
    public var minithumbnail: Data?
    public var caption: String

    init(_ photo: Photo, caption: String) {
        sizes = photo.sizes.map { (fileId: $0.photo.id, width: $0.width, height: $0.height) }
        minithumbnail = photo.minithumbnail?.data
        self.caption = caption
    }

    /// The smallest size that still covers the target, in *pixels* — a 2× panel
    /// asking for 320 pt needs 640 px, and picking by points makes every photo
    /// soft on Retina.
    public func bestSize(forWidth points: CGFloat, scale: CGFloat) -> (fileId: Int, width: Int, height: Int)? {
        let target = Int((points * scale).rounded())
        return sizes.first { $0.width >= target } ?? sizes.last
    }

    public var aspectRatio: CGFloat {
        guard let largest = sizes.last, largest.height > 0 else { return 1 }
        return CGFloat(largest.width) / CGFloat(largest.height)
    }

    public static func == (lhs: PhotoDescriptor, rhs: PhotoDescriptor) -> Bool {
        lhs.caption == rhs.caption
            && lhs.minithumbnail == rhs.minithumbnail
            && lhs.sizes.map(\.fileId) == rhs.sizes.map(\.fileId)
    }
}

public struct StickerDescriptor: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        /// Decodes natively through ImageIO.
        case webp
        /// Gzipped Lottie. Needs a renderer that does not exist here (T3).
        case tgs
        /// **Unplayable on macOS 26**: no webm/matroska UTI in AVFoundation.
        case webm
    }

    public var format: Format
    public var fileId: Int
    public var thumbnailFileId: Int?
    public var emoji: String
    public var width: Int
    public var height: Int

    /// True when the sticker itself can be drawn; false means fall back to the
    /// thumbnail, which is a plain image TDLib always provides.
    public var isRenderable: Bool { format == .webp }

    init(_ sticker: Sticker) {
        switch sticker.format {
        case .stickerFormatWebp: format = .webp
        case .stickerFormatTgs: format = .tgs
        case .stickerFormatWebm: format = .webm
        }
        fileId = sticker.sticker.id
        thumbnailFileId = sticker.thumbnail?.file.id
        emoji = sticker.emoji
        width = sticker.width
        height = sticker.height
    }
}

public struct AnimationDescriptor: Equatable, Sendable {
    public var fileId: Int
    public var thumbnailFileId: Int?
    public var minithumbnail: Data?
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var duration: Int
    public var caption: String

    /// Telegram sends most "GIFs" as silent mp4. Branch on this, not on the
    /// file name.
    public var isVideoContainer: Bool { mimeType.hasPrefix("video/") }

    init(_ animation: Animation, caption: String) {
        fileId = animation.animation.id
        thumbnailFileId = animation.thumbnail?.file.id
        minithumbnail = animation.minithumbnail?.data
        mimeType = animation.mimeType
        width = animation.width
        height = animation.height
        duration = animation.duration
        self.caption = caption
    }
}

public struct VoiceDescriptor: Equatable, Sendable {
    public var fileId: Int
    public var duration: Int
    public var waveform: Data
    public var isListened: Bool
    public var transcript: TranscriptState

    init(_ note: VoiceNote, isListened: Bool) {
        fileId = note.voice.id
        duration = note.duration
        waveform = note.waveform
        self.isListened = isListened
        transcript = TranscriptState(note.speechRecognitionResult)
    }

    /// Telegram packs the waveform as 5-bit samples. Unpacking it is what makes
    /// the bars match what every other client draws.
    public func bars(count: Int) -> [CGFloat] {
        let bits = waveform.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 } }
        var samples: [CGFloat] = []
        var index = 0
        while index + 5 <= bits.count {
            var value = 0
            for offset in 0..<5 { value = (value << 1) | Int(bits[index + offset]) }
            samples.append(CGFloat(value) / 31)
            index += 5
        }
        guard !samples.isEmpty else { return Array(repeating: 0.3, count: count) }
        guard samples.count > count else { return samples }
        // Downsample by taking the loudest sample per bucket, so a quiet stretch
        // between two peaks does not flatten the whole bar.
        let bucket = Double(samples.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * bucket)
            let end = min(samples.count, Int(Double(index + 1) * bucket) + 1)
            return samples[start..<end].max() ?? 0
        }
    }
}

public struct VideoDescriptor: Equatable, Sendable {
    public var fileId: Int
    public var thumbnailFileId: Int?
    public var minithumbnail: Data?
    public var duration: Int
    public var width: Int
    public var height: Int
    public var fileName: String
    public var caption: String

    init(_ video: Video, caption: String) {
        fileId = video.video.id
        thumbnailFileId = video.thumbnail?.file.id
        minithumbnail = video.minithumbnail?.data
        duration = video.duration
        width = video.width
        height = video.height
        fileName = video.fileName
        self.caption = caption
    }
}

public struct DocumentDescriptor: Equatable, Sendable {
    public var fileId: Int
    public var fileName: String
    public var mimeType: String
    public var size: Int64
    public var caption: String

    init(_ document: Document, caption: String) {
        fileId = document.document.id
        fileName = document.fileName
        mimeType = document.mimeType
        size = document.document.size > 0 ? document.document.size : document.document.expectedSize
        self.caption = caption
    }
}

/// `mm:ss`, which is how Telegram writes every duration.
public func formatDuration(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let remainder = seconds % 60
    return String(format: "%d:%02d", minutes, remainder)
}

public func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
