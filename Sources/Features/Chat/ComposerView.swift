import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message composer.
///
/// Enter sends, Shift+Enter inserts a newline — `TextField(axis: .vertical)` +
/// `.onSubmit` is exactly that pairing on macOS, and it is backed by a real
/// field editor, so IME, selection and ⌘V all work without an NSTextView bridge.
///
/// The draft lives in the **shared** panel store, not in this view: a display
/// hot-plug rebuilds every panel, and a draft held here would vanish with the
/// window mid-sentence.
struct ComposerView: View {
    let chatId: Int64
    let shared: PanelSharedState
    var onSend: (String) -> Void
    var onSendFiles: ([URL]) -> Void
    var setPin: (PanelSharedState.PinReason, Bool) -> Void

    @FocusState private var isFocused: Bool

    private var text: Binding<String> {
        Binding(
            get: { shared.draft(for: chatId) },
            set: { shared.setDraft($0, for: chatId) })
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PanelIconButton(systemName: "paperclip", iconSize: 15, side: 28, action: attach)
                .accessibilityIdentifier("composer-attach")

            TextField(L10n.s("Message", "Сообщение"), text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.messageBody)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1...6)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .insetGlass(cornerRadius: 15, focused: isFocused)
                .animation(Theme.Motion.quick, value: isFocused)
                .focused($isFocused)
                .onSubmit(send)
                // Typing with the pointer parked outside the panel must not
                // collapse it mid-sentence. The reason clears on the falling
                // focus edge and on teardown — whichever comes first.
                .onChange(of: isFocused) { _, focused in setPin(.composerFocus, focused) }
                .onDisappear { setPin(.composerFocus, false) }
                // Paste is handled strictly as ⌘V through the responder chain.
                // Never poll `NSPasteboard.general.changeCount`: on macOS 26
                // that lands the app in the "Paste from Other Apps" privacy
                // pane, and one Deny breaks image paste permanently.
                .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg], perform: paste)
                .accessibilityIdentifier("composer")

            // Arms with a pop the moment there is something to send: quiet
            // glass disc → solid ice with an ink arrow.
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        canSend ? Color.black.opacity(0.85) : Theme.Palette.textTertiary)
                    .frame(width: 27, height: 27)
                    .background(
                        canSend
                            ? AnyShapeStyle(Theme.Palette.accent)
                            : AnyShapeStyle(Color.white.opacity(0.06)),
                        in: .circle)
                    .overlay {
                        if !canSend {
                            Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                        }
                    }
                    .scaleEffect(canSend ? 1 : 0.9)
                    .animation(Theme.Motion.pop, value: canSend)
            }
            .buttonStyle(.pressable)
            .disabled(!canSend)
            .accessibilityIdentifier("composer-send")
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, 8)
        .background(Theme.Palette.surfaceRaised)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Palette.separator).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !shared.draft(for: chatId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes pasted image data to a temp file, because TDLib sends files by
    /// path — there is no in-memory input.
    private func paste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in onSendFiles([url]) }
                }
                continue
            }
            for type in [UTType.png, .tiff, .jpeg] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("notchgram-paste-\(UUID().uuidString)")
                        .appendingPathExtension(type.preferredFilenameExtension ?? "png")
                    try? data.write(to: url)
                    Task { @MainActor in onSendFiles([url]) }
                }
                break
            }
        }
    }

    /// Exactly one picker at a time — `begin` is non-modal, so without the
    /// guard every extra click on the paperclip stacked another open dialog.
    /// The panel is held open for the picker's whole lifetime: choosing a
    /// file means the pointer leaves the panel, and the panel folding away
    /// under a file dialog reads as the app disappearing. The pin itself is
    /// the guard — unlike the old `@State` flag it survives a view rebuild.
    private func attach() {
        guard !shared.activePins.contains(.filePicker) else { return }
        setPin(.filePicker, true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // The notch panel floats at `.statusBar`; a default-level dialog opens
        // *underneath* it, which made picking a file a drag-the-window chore.
        let anchor = NSApp.keyWindow
        panel.level = anchor?.level ?? .statusBar
        panel.begin { response in
            let urls = panel.urls
            Task { @MainActor in
                // Per-reason holds cannot clobber each other: releasing the
                // picker's hold leaves a focused composer's hold standing, so
                // cancelling the dialog mid-sentence keeps the panel up.
                setPin(.filePicker, false)
                setPin(.composerFocus, isFocused)
                guard response == .OK else { return }
                onSendFiles(urls)
            }
        }
        // Park the dialog just below the notch panel instead of centred over
        // it, clamped to the visible frame so it never runs under the Dock.
        if let anchor, let screen = anchor.screen {
            let size = panel.frame.size
            let x = min(
                max(anchor.frame.midX - size.width / 2, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - size.width - 8)
            let y = max(anchor.frame.minY - size.height - 12, screen.visibleFrame.minY + 8)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func send() {
        let draft = shared.draft(for: chatId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        shared.setDraft("", for: chatId)
        onSend(draft)
        // Clicking the send button lands outside the field, which now ends the
        // editing session — take it back, like Telegram's input does.
        isFocused = true
    }
}
