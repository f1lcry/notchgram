import Foundation
@preconcurrency import TDLibKit

/// The L2 verification: a full cold-start → login → send → read-back → media
/// round trip on a throwaway test-DC account, with no founder involvement.
enum RoundTrip {

    /// One attempt against one data centre. Returns the steps it managed and
    /// throws on the first hard failure.
    static func run(dcId: Int, steps: inout [StepResult]) async throws {
        let account = TestAccount(dcId: dcId)
        note("attempt on dc \(dcId): \(account.phoneNumber)")

        let harness = try Harness(account: account)
        await harness.start()
        defer { harness.cleanUp() }

        // 1 — cold start through registration to Ready.
        try await step("auth", &steps) {
            try await harness.waitForReady()
            return await harness.trail
        }

        // 2 — identity, and Saved Messages as the round-trip target. It needs
        // no setup: a private chat with yourself IS Saved Messages.
        let myUserId = try await step("getMe", &steps) { () -> Int64 in
            try await harness.client.getMe().id
        }

        let savedMessages = try await step("savedMessages", &steps) { () -> Int64 in
            let chat = try await harness.client.createPrivateChat(userId: myUserId, force: false)
            return chat.id
        }

        // 3 — text round trip. The UUID payload is what makes the read-back
        // assertion meaningful: it cannot be satisfied by anything else.
        let token = UUID().uuidString
        let sendingId = TDClient.newSendingId()
        let temporary = try await step("sendText", &steps) { () -> Int64 in
            let message = try await harness.client.sendText(
                chatId: savedMessages, text: "notchgram-itest \(token)", sendingId: sendingId)
            return message.id
        }

        let confirmed = try await step("sendSucceeded", &steps) { () -> Message in
            try await harness.waitForSendSucceeded(temporaryId: temporary)
        }
        // Server ids are `server_id << 20`, so a real server message has the
        // low 20 bits clear. A temporary id does not.
        guard confirmed.id % 1_048_576 == 0 else {
            throw TDError(code: 0, message: "confirmed id \(confirmed.id) is not a server id")
        }

        try await step("historyReadback", &steps) { () -> String in
            // TDLib documents that the first getChatHistory on a cold cache may
            // return 0–1 messages regardless of `limit`, so loop rather than
            // trusting one call.
            var seen: [Message] = []
            var from: Int64 = 0
            for _ in 0..<10 {
                let page = try await harness.client.chatHistory(
                    chatId: savedMessages, fromMessageId: from, limit: 20)
                if page.isEmpty { break }
                seen.append(contentsOf: page)
                if seen.contains(where: { containsText($0, token) }) { break }
                from = page.last?.id ?? 0
            }
            guard seen.contains(where: { containsText($0, token) }) else {
                throw TDError(code: 0, message: "sent text not found in history (\(seen.count) read)")
            }
            return "found token in \(seen.count) messages"
        }

        // 4 — media round trip: upload a small PNG, then download it back.
        let pngURL = harness.root.appendingPathComponent("probe.png")
        let dimensions = try writeTestPNG(to: pngURL)

        let photoSendingId = TDClient.newSendingId()
        let photoTemporary = try await step("sendPhoto", &steps) { () -> Int64 in
            let message = try await harness.client.sendPhoto(
                chatId: savedMessages,
                path: pngURL.path,
                width: dimensions.width,
                height: dimensions.height,
                caption: "itest \(token)",
                sendingId: photoSendingId)
            return message.id
        }

        let photoMessage = try await step("photoUpload", &steps) { () -> Message in
            try await harness.waitForSendSucceeded(temporaryId: photoTemporary)
        }

        guard case .messagePhoto(let content) = photoMessage.content,
              let largest = content.photo.sizes.max(by: { $0.width * $0.height < $1.width * $1.height })
        else {
            throw TDError(code: 0, message: "sent message is not a photo")
        }

        try await step("photoDownload", &steps) { () -> String in
            // Asynchronous on purpose: `synchronous: true` would stall the actor
            // for the whole transfer. Completion arrives as `updateFile`.
            _ = try await harness.client.downloadFile(fileId: largest.photo.id)
            let file = try await harness.waitForDownload(fileId: largest.photo.id)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.local.path)[.size])
                as? Int64 ?? 0
            guard size > 0 else {
                throw TDError(code: 0, message: "downloaded file is empty at \(file.local.path)")
            }
            return "\(size) bytes, \(largest.width)x\(largest.height)"
        }

        // 5 — clean close, so TDLib flushes its encrypted database.
        try await step("close", &steps) { () -> String in
            await harness.stop()
            return "closed"
        }
    }

    private static func containsText(_ message: Message, _ needle: String) -> Bool {
        switch message.content {
        case .messageText(let content): content.text.text.contains(needle)
        case .messagePhoto(let content): content.caption.text.contains(needle)
        default: false
        }
    }

    /// Records timing and outcome for the JSON report; rethrows so the caller
    /// can decide whether to retry the whole attempt.
    @discardableResult
    private static func step<T>(
        _ name: String,
        _ steps: inout [StepResult],
        _ body: () async throws -> T
    ) async throws -> T {
        let start = ContinuousClock.now
        do {
            let value = try await body()
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            steps.append(StepResult(
                name: name, ok: true, seconds: seconds,
                detail: (value as? CustomStringConvertible).map { "\($0)" }))
            note("✓ \(name) (\(String(format: "%.1f", seconds)) s)")
            return value
        } catch {
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            let detail = (error as? TDError)?.message
                ?? (error as? TDTimeout)?.errorDescription
                ?? String(describing: error)
            steps.append(StepResult(name: name, ok: false, seconds: seconds, detail: detail))
            note("✗ \(name): \(detail)")
            throw error
        }
    }
}
