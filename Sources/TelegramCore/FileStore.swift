import Foundation
import Observation
import os
@preconcurrency import TDLibKit

/// One file's transfer state, as a value.
public struct FileState: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    /// **Only meaningful when `isDownloaded` is true.** TDLib's own docs warn
    /// that `local.path` may point at a partial file and that the bytes on disk
    /// "may contain garbage" until completion, so rendering from a non-empty
    /// path alone shows corrupt images.
    public var path: String
    public var isDownloaded: Bool
    public var isDownloading: Bool
    public var downloadedSize: Int64
    public var expectedSize: Int64
    public var isUploaded: Bool
    public var uploadedSize: Int64

    public init(_ file: File) {
        id = file.id
        path = file.local.path
        isDownloaded = file.local.isDownloadingCompleted && !file.local.path.isEmpty
        isDownloading = file.local.isDownloadingActive
        downloadedSize = file.local.downloadedSize
        expectedSize = file.size > 0 ? file.size : file.expectedSize
        isUploaded = file.remote.isUploadingCompleted
        uploadedSize = file.remote.uploadedSize
    }

    /// 0…1, or nil when the size is unknown. `downloadedSize` is for progress
    /// arithmetic only — see the note on `path`.
    public var downloadProgress: Double? {
        guard expectedSize > 0 else { return nil }
        return min(1, Double(downloadedSize) / Double(expectedSize))
    }

    public var uploadProgress: Double? {
        guard expectedSize > 0 else { return nil }
        return min(1, Double(uploadedSize) / Double(expectedSize))
    }

    public var url: URL? { isDownloaded ? URL(fileURLWithPath: path) : nil }
}

/// One file's observable slot.
///
/// **Why a box per file, not one published dictionary.** `@Observable` tracks
/// access at property granularity: a single `files: [Int: FileState]` property
/// means *every* progress tick of *any* download invalidates *every* view that
/// reads *any* file — during a media-heavy chat's initial burst that is the
/// whole message list re-rendering at network speed. A view that reads
/// `box.state` observes exactly its own file and nothing else.
@MainActor
@Observable
public final class FileBox: Identifiable {
    public let id: Int
    public internal(set) var state: FileState?
    /// Monotonic access stamp for the store's LRU sweep.
    @ObservationIgnored var lastTouch: UInt64 = 0

    init(id: Int) {
        self.id = id
    }
}

/// Downloads and their progress.
///
/// `updateFile` carries both download *and* upload progress for the same file
/// id, which is why one store covers both directions.
@MainActor
@Observable
public final class FileStore: TelegramUpdateSink {
    /// Progress writes are throttled: TDLib streams `updateFile` at network
    /// speed, and publishing every tick would render progress bars at hundreds
    /// of frames a second. State *transitions* always publish.
    static let progressPublishStep: Int64 = 256 * 1024
    /// `boxes` grew monotonically for the process lifetime (every file ever
    /// seen). Past this many, the least-recently-touched half is swept; a
    /// swept box is recreated on the next `box(for:)`, so the only cost is a
    /// missed progress tick on a row nobody is looking at.
    static let maxBoxes = 2048

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "FileStore")
    @ObservationIgnored private var boxes: [Int: FileBox] = [:]
    @ObservationIgnored private var requested: Set<Int> = []
    @ObservationIgnored private var touchCounter: UInt64 = 0
    private weak var client: TDClient?

    public init() {}

    public func attach(client: TDClient) {
        self.client = client
    }

    /// The observable slot for a file. Creating it on first read is what makes
    /// "render nil now, re-render when the download lands" work: there is
    /// always an object whose `state` the view is tracking.
    public func box(for fileId: Int) -> FileBox {
        touchCounter += 1
        if let box = boxes[fileId] {
            box.lastTouch = touchCounter
            return box
        }
        sweepIfNeeded()
        let box = FileBox(id: fileId)
        box.lastTouch = touchCounter
        boxes[fileId] = box
        return box
    }

    /// LRU sweep, run before a new box is created past the cap. Boxes with an
    /// active transfer are never dropped — their `updateFile` stream must keep
    /// landing somewhere observable.
    private func sweepIfNeeded() {
        guard boxes.count >= Self.maxBoxes else { return }
        let victims = boxes.values
            .filter { $0.state?.isDownloading != true }
            .sorted { $0.lastTouch < $1.lastTouch }
            .prefix(Self.maxBoxes / 2)
        for box in victims {
            boxes.removeValue(forKey: box.id)
        }
        log.notice("swept \(victims.count, privacy: .public) file boxes")
    }

    public func state(for fileId: Int) -> FileState? { box(for: fileId).state }

    public func localURL(for fileId: Int) -> URL? { box(for: fileId).state?.url }

    /// Starts a download if one is not already known to be running.
    ///
    /// Asynchronous on purpose: `downloadFile(synchronous: true)` stalls the
    /// actor until the entire transfer finishes. Completion arrives as
    /// `updateFile`, which is what the views observe.
    public func requestDownload(_ fileId: Int, priority: Int = 16) {
        guard fileId != 0, !requested.contains(fileId) else { return }
        if box(for: fileId).state?.isDownloaded == true { return }
        requested.insert(fileId)

        guard let client else { return }
        Task { [weak self] in
            do {
                let file = try await client.downloadFile(fileId: fileId, priority: priority)
                self?.publish(FileState(file))
            } catch {
                self?.requested.remove(fileId)
                self?.log.error(
                    "downloadFile(\(fileId, privacy: .public)) failed: \(TDError.wrap(error).message, privacy: .public)")
            }
        }
    }

    /// Records a file seen inside a message so its progress is known before any
    /// download is requested.
    public func observe(_ file: File) {
        publish(FileState(file))
    }

    public func apply(_ update: Update) {
        guard case .updateFile(let payload) = update else { return }
        let fresh = FileState(payload.file)
        let box = box(for: payload.file.id)
        if Self.shouldPublish(old: box.state, new: fresh) {
            box.state = fresh
        }
        if payload.file.local.isDownloadingCompleted {
            requested.remove(payload.file.id)
        }
    }

    private func publish(_ state: FileState) {
        let box = box(for: state.id)
        if Self.shouldPublish(old: box.state, new: state) {
            box.state = state
        }
    }

    static func shouldPublish(old: FileState?, new: FileState) -> Bool {
        guard let old else { return true }
        if old.isDownloaded != new.isDownloaded { return true }
        if old.isDownloading != new.isDownloading { return true }
        if old.isUploaded != new.isUploaded { return true }
        if old.path != new.path { return true }
        if abs(new.downloadedSize - old.downloadedSize) >= progressPublishStep { return true }
        if abs(new.uploadedSize - old.uploadedSize) >= progressPublishStep { return true }
        return false
    }
}
