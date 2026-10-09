import Foundation
@preconcurrency import TDLibKit
import UserNotifications
import os

/// Desktop notifications for incoming messages (D21).
///
/// The pragmatic path, deliberately: TDLib's real
/// `updateNotificationGroup`/`updateActiveNotifications` machinery gives
/// cross-restart dedup, remote dismissal, mention grouping and `show_preview`
/// handling for free, and it is Session 2 work. This posts from
/// `updateNewMessage` instead, with the four things that path would otherwise
/// get wrong done by hand:
///
/// 1. **Outgoing messages never notify.** Obvious, and the first thing a naive
///    implementation gets wrong because `updateNewMessage` fires for them too.
/// 2. **Mute is resolved, not read.** `chatNotificationSettings.use_default_mute_for`
///    makes `mute_for` meaningless on its own; a chat on defaults follows its
///    scope. `ChatRepo` already resolves this, so the answer comes from there.
/// 3. **Dedup survives a restart.** TDLib re-delivers recent messages on a cold
///    start, so a naive notifier announces yesterday's conversation every launch.
///    Seen `(chatId, messageId)` pairs are persisted.
/// 4. **Reading clears them.** `updateChatReadInbox` withdraws anything still on
///    screen for that chat, so the badge and the banners agree.
///
/// **Unverified in this session.** `UNUserNotificationCenter.authorizationStatus`
/// is `.denied` for this bundle id, so nothing can actually be delivered until
/// the founder re-enables it in System Settings. The code path runs and logs.
@MainActor
final class MessageNotifier: TelegramUpdateSink {
    private static let seenKey = "NotifiedMessages"
    private static let seenLimit = 400

    private let log = Logger(subsystem: "com.f1lcry.notchgram", category: "Notifier")
    private let defaults: UserDefaults
    private let chatRepo: ChatRepo
    private let shared: PanelSharedState

    /// `"chatId:messageId"`, newest last.
    private var seen: [String]
    private var seenSet: Set<String>

    init(chatRepo: ChatRepo, shared: PanelSharedState, defaults: UserDefaults = .standard) {
        self.chatRepo = chatRepo
        self.shared = shared
        self.defaults = defaults
        self.seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        self.seenSet = Set(seen)
    }

    func apply(_ update: Update) {
        switch update {
        case .updateNewMessage(let payload):
            handle(payload.message)
        case .updateChatReadInbox(let payload):
            // Reading elsewhere — on the phone, or in this panel — should take
            // the banner down rather than leave it contradicting the badge.
            withdraw(chatId: payload.chatId)
        default:
            break
        }
    }

    private func handle(_ message: Message) {
        guard !message.isOutgoing else { return }
        // The chat that is open and on screen is being read; a banner for it is
        // noise.
        guard shared.openChatId != message.chatId else { return }

        let summary = chatRepo.chats.first { $0.id == message.chatId }
        guard summary?.isMuted != true else { return }

        let key = "\(message.chatId):\(message.id)"
        guard !seenSet.contains(key) else { return }
        remember(key)

        let content = UNMutableNotificationContent()
        content.title = summary?.title ?? "Telegram"
        content.body = MessagePreview.text(for: message.content)
        content.sound = .default
        content.threadIdentifier = String(message.chatId)
        content.userInfo = ["chatId": message.chatId]

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: key, content: content, trigger: nil)
        ) { [log] error in
            if let error {
                log.notice("notification not delivered: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func withdraw(chatId: Int64) {
        let prefix = "\(chatId):"
        let identifiers = seen.filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Bounded: without a cap this list grows for the life of the install.
    private func remember(_ key: String) {
        seen.append(key)
        seenSet.insert(key)
        if seen.count > Self.seenLimit {
            let dropped = seen.prefix(seen.count - Self.seenLimit)
            seen.removeFirst(seen.count - Self.seenLimit)
            seenSet.subtract(dropped)
        }
        defaults.set(seen, forKey: Self.seenKey)
    }
}
