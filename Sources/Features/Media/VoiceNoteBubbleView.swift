import AVFoundation
import Observation
import SwiftUI

/// Plays one voice note.
///
/// **`AVAudioPlayer`, not `AVURLAsset`/`AVPlayer`.** Measured on this machine:
/// `AVURLAsset` sniffing is extension-dependent for Ogg — a downloaded voice
/// note with no file extension reports `isPlayable == false` and zero tracks,
/// which is exactly how TDLib stores them. `AVAudioPlayer(contentsOf:)` opened
/// every case tried, including a 105-second Ogg/Opus file with no extension.
/// `AVPlayer` stays reserved for mp4 (GIFs and video).
@MainActor
@Observable
final class VoiceNotePlayer {
    private(set) var isPlaying = false
    private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func toggle(url: URL) {
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    private func play(url: URL) {
        if player == nil {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
        }
        guard let player else { return }
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let player = self.player else { return }
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                if !player.isPlaying {
                    self.isPlaying = false
                    // A finished note rewinds, so tapping again replays it
                    // instead of doing nothing.
                    if self.progress > 0.99 {
                        player.currentTime = 0
                        self.progress = 0
                    }
                    return
                }
            }
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }
}

struct VoiceNoteBubbleView: View {
    let voice: VoiceDescriptor
    let fileStore: FileStore
    /// Asks Telegram to transcribe this note (C6).
    var onTranscribe: (() -> Void)?

    @State private var player = VoiceNotePlayer()

    private static let barCount = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    ZStack {
                        Circle().fill(Theme.Palette.accent).frame(width: 30, height: 30)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(url == nil)

                VStack(alignment: .leading, spacing: 4) {
                    waveform
                    Text(formatDuration(voice.duration))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                if let onTranscribe, showsTranscribeButton {
                    TranscribeButton(action: onTranscribe)
                }
            }

            TranscriptView(state: voice.transcript)
        }
        .onAppear { fileStore.requestDownload(voice.fileId, priority: 24) }
        .accessibilityIdentifier("media-voice")
    }

    private var showsTranscribeButton: Bool {
        switch voice.transcript {
        case .none, .failed: true
        case .pending, .done: false
        }
    }

    /// Telegram packs the waveform as 5-bit samples; unpacking it is what makes
    /// the bars match every other client rather than being decorative noise.
    private var waveform: some View {
        let bars = voice.bars(count: Self.barCount)
        let played = Int(Double(bars.count) * player.progress)
        return HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= played
                          ? Theme.Palette.accent
                          : Theme.Palette.textTertiary.opacity(0.6))
                    .frame(width: 2, height: max(3, bars[index] * 20))
            }
        }
        .frame(height: 20)
    }

    private var url: URL? { fileStore.localURL(for: voice.fileId) }

    private func toggle() {
        guard let url else { return }
        player.toggle(url: url)
    }
}

/// Telegram's "→A" pill.
struct TranscribeButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("→A")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Theme.Palette.accentMuted, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcribe")
    }
}

/// The transcription itself, under the note — pending shows Telegram's
/// partial text as it streams in; the Premium gate explains itself.
struct TranscriptView: View {
    let state: TranscriptState

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .pending(let partial):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(partial.isEmpty ? L10n.s("Transcribing…", "Распознавание…") : partial)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("transcript-pending")
        case .done(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(Color.black.opacity(0.2), in: .rect(cornerRadius: 8))
                .accessibilityIdentifier("transcript-text")
        case .failed(let message):
            Text(message.localizedCaseInsensitiveContains("premium")
                ? L10n.s(
                    "Transcription needs Telegram Premium",
                    "Транскрибация доступна с Telegram Premium")
                : message)
                .font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityIdentifier("transcript-error")
        }
    }
}
