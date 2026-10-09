// Debug builds only (D43): the public Release build must not contain the
// agent control channel or its helpers, not merely have them switched off.
#if DEBUG

import AppKit
import UserNotifications
import os

/// How the build session reaches the founder for a checkpoint.
///
/// CP1 — the one interactive Telegram login — is delivered *by* a notification,
/// which makes the notification a single point of failure. It already failed
/// once here: `authorizationStatus` is `.denied` for this bundle id, so
/// `requestAuthorization` can never succeed until somebody re-enables it in
/// System Settings. A checkpoint that silently does not arrive is worse than one
/// that arrives twice, so every channel is tried and none is trusted:
///
/// 1. a user notification, if the grant exists;
/// 2. `osascript display notification`, which goes through a different
///    permission and often works when the first does not;
/// 3. a **file** in `.artifacts/`, which needs no permission at all and is what
///    the session report and the agent read.
///
/// The file is the one that actually has to work.
@MainActor
enum CheckpointNotifier {
    private static let log = Logger(subsystem: "com.f1lcry.notchgram", category: "Checkpoint")

    /// Written next to the rest of the evidence, and deliberately human-readable:
    /// the founder may find it before reading anything else.
    static var statusFileURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".artifacts/CHECKPOINT.md")
    }

    static func fire(title: String, body: String, details: String) {
        writeStatusFile(title: title, body: body, details: details)
        postUserNotification(title: title, body: body)
        postAppleScriptNotification(title: title, body: body)
        log.notice("checkpoint fired: \(title, privacy: .public)")
    }

    private static func writeStatusFile(title: String, body: String, details: String) {
        let text = """
            # \(title)

            \(body)

            \(details)
            """
        let url = statusFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func postUserNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "notchgram.checkpoint.\(title.hashValue)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // Expected while the grant is denied; the file already landed.
                Logger(subsystem: "com.f1lcry.notchgram", category: "Checkpoint")
                    .notice("user notification unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Goes through the *script* runner's notification permission rather than
    /// the app's, so it frequently succeeds where the first channel does not.
    private static func postAppleScriptNotification(title: String, body: String) {
        let escape: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }
}

#endif
