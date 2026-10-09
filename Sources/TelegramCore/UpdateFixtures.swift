import Foundation
@preconcurrency import TDLibKit

/// Synthesized `Update` values.
///
/// These exist because Telegram's test-DC simplified login is broken
/// server-side (see `docs/sessions/session-01-report.md` and tdlib/td#3083), so
/// there is no automated way to get *real* chats and messages flowing without
/// the founder's account. Mocking the **inbound** direction — the update stream
/// — costs little and buys a lot:
///
/// - the repos are `apply(Update)` functions, so replaying a sequence tests the
///   real code path, not a stand-in;
/// - it is the only way to reproduce the sequences that are hard to provoke on
///   demand and easy to get wrong: `updateChatLastMessage` arriving *instead of*
///   `updateChatPosition`, a send whose confirmation replaces the whole message
///   object, a `fromCache` delete that is not a real delete;
/// - DebugBridge can inject them into the running app, so the chat-list and
///   conversation UI can be built and screenshotted before an account exists.
///
/// The **outbound** direction is deliberately not faked. A round trip that
/// asserts "the text I sent appears in history" against a fake that put it there
/// proves nothing; that assertion belongs to the L4 real-account probe.
public enum UpdateFixtures {

    // MARK: - Ids

    /// TDLib chat ids: users are positive, basic groups are negative, and
    /// supergroups/channels are large negative numbers. Keeping fixtures in the
    /// real ranges catches sign bugs in the UI.
    public static func privateChatId(_ n: Int64) -> Int64 { n }
    public static func basicGroupChatId(_ n: Int64) -> Int64 { -n }
    public static func supergroupChatId(_ n: Int64) -> Int64 { -1_000_000_000_000 - n }

    /// Server message ids are `server_id << 20`, so the low 20 bits are clear.
    /// A temporary (not yet sent) id is not aligned this way — which is exactly
    /// the test for "is this a real server message".
    public static func serverMessageId(_ n: Int64) -> Int64 { n << 20 }
    public static func temporaryMessageId(_ n: Int64) -> Int64 { (n << 20) + 1 }

    // MARK: - People

    public static func user(
        id: Int64,
        firstName: String,
        lastName: String = "",
        phoneNumber: String = "",
        profilePhoto: ProfilePhoto? = nil,
        type: UserType = .userTypeRegular,
        usernames: Usernames? = nil
    ) -> User {
        User(
            accentColorId: 0,
            activeStoryState: nil,
            addedToAttachmentMenu: false,
            backgroundCustomEmojiId: TdInt64(0),
            emojiStatus: nil,
            firstName: firstName,
            haveAccess: true,
            id: id,
            isCloseFriend: false,
            isContact: true,
            isMutualContact: true,
            isPremium: false,
            isSupport: false,
            languageCode: "en",
            lastName: lastName,
            paidMessageStarCount: 0,
            phoneNumber: phoneNumber,
            profileAccentColorId: 0,
            profileBackgroundCustomEmojiId: TdInt64(0),
            profilePhoto: profilePhoto,
            restrictionInfo: nil,
            restrictsNewChats: false,
            status: .userStatusOffline(UserStatusOffline(wasOnline: 0)),
            type: type,
            upgradedGiftColors: nil,
            usernames: usernames,
            verificationStatus: nil)
    }

    // MARK: - Content

    public static func text(_ value: String) -> MessageContent {
        .messageText(MessageText(
            linkPreview: nil,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: value)))
    }

    /// Text with entities. Offsets and lengths are UTF-16 code units, exactly
    /// as TDLib sends them.
    public static func text(_ value: String, entities: [TextEntity]) -> MessageContent {
        .messageText(MessageText(
            linkPreview: nil,
            linkPreviewOptions: nil,
            text: FormattedText(entities: entities, text: value)))
    }

    /// A `textEntityTypeUrl` entity covering the first occurrence of `url`
    /// in `text`, in UTF-16 units.
    public static func urlEntity(_ url: String, in text: String) -> TextEntity? {
        guard let range = text.range(of: url) else { return nil }
        let offset = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
        return TextEntity(length: url.utf16.count, offset: offset, type: .textEntityTypeUrl)
    }

    public static func file(
        id: Int,
        size: Int64 = 1024,
        downloadedCompleted: Bool = false,
        path: String = "",
        uploadCompleted: Bool = true
    ) -> File {
        File(
            expectedSize: size,
            id: id,
            local: LocalFile(
                canBeDeleted: true,
                canBeDownloaded: true,
                downloadOffset: 0,
                downloadedPrefixSize: downloadedCompleted ? size : 0,
                downloadedSize: downloadedCompleted ? size : 0,
                isDownloadingActive: false,
                isDownloadingCompleted: downloadedCompleted,
                path: path),
            remote: RemoteFile(
                id: "remote-\(id)",
                isUploadingActive: false,
                isUploadingCompleted: uploadCompleted,
                uniqueId: "unique-\(id)",
                uploadedSize: uploadCompleted ? size : 0),
            size: size)
    }

    /// Photo content. `sizes` is empty by default — a chat-list preview never
    /// reads it, and a renderer that assumes at least one size is a bug worth
    /// catching.
    public static func photo(
        caption: String = "",
        sizes: [PhotoSize] = [],
        minithumbnail: Minithumbnail? = nil
    ) -> MessageContent {
        .messagePhoto(MessagePhoto(
            caption: FormattedText(entities: [], text: caption),
            hasSpoiler: false,
            isSecret: false,
            photo: Photo(hasStickers: false, minithumbnail: minithumbnail, sizes: sizes),
            showCaptionAboveMedia: false,
            video: nil))
    }

    public static func photoSize(
        type: String = "x", fileId: Int = 1, width: Int = 800, height: Int = 600
    ) -> PhotoSize {
        PhotoSize(
            height: height,
            photo: file(id: fileId, size: 120_000),
            progressiveSizes: [],
            type: type,
            width: width)
    }

    /// Voice note. Ogg/Opus is what Telegram actually sends, and
    /// `AVAudioPlayer` — not `AVURLAsset` — is what can open it without a file
    /// extension.
    public static func voiceNote(
        caption: String = "", duration: Int = 5, fileId: Int = 2,
        waveform: Data = Data(repeating: 0x55, count: 32),
        voice: File? = nil
    ) -> MessageContent {
        .messageVoiceNote(MessageVoiceNote(
            caption: FormattedText(entities: [], text: caption),
            isListened: false,
            voiceNote: VoiceNote(
                duration: duration,
                mimeType: "audio/ogg",
                speechRecognitionResult: nil,
                voice: voice ?? file(id: fileId, size: 24_000),
                waveform: waveform)))
    }

    public static func draft(_ text: String) -> DraftMessage {
        DraftMessage(
            content: .draftMessageContentText(DraftMessageContentText(
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text))),
            date: 0,
            effectId: TdInt64(0),
            replyTo: nil,
            suggestedPostInfo: nil)
    }

    /// Scope-level notification settings. `muteFor > 0` is what a chat on
    /// defaults inherits — the reason `use_default_mute_for` has to be resolved
    /// rather than ignored.
    public static func scopeSettings(muteFor: Int) -> ScopeNotificationSettings {
        ScopeNotificationSettings(
            disableMentionNotifications: false,
            disablePinnedMessageNotifications: false,
            muteFor: muteFor,
            muteStories: false,
            showPreview: true,
            showStoryPoster: true,
            soundId: TdInt64(0),
            storySoundId: TdInt64(0),
            useDefaultMuteStories: true)
    }

    // MARK: - Messages

    public static func message(
        id: Int64,
        chatId: Int64,
        senderUserId: Int64,
        content: MessageContent,
        isOutgoing: Bool = false,
        date: Int = 1_700_000_000,
        sendingState: MessageSendingState? = nil,
        mediaAlbumId: Int64 = 0,
        replyToMessageId: Int64? = nil,
        interactionInfo: MessageInteractionInfo? = nil
    ) -> Message {
        Message(
            authorSignature: "",
            autoDeleteIn: 0,
            canBeSaved: true,
            chatId: chatId,
            containsUnreadMention: false,
            containsUnreadPollVotes: false,
            content: content,
            date: date,
            editDate: 0,
            effectId: TdInt64(0),
            ephemeralMessageId: 0,
            factCheck: nil,
            forwardInfo: nil,
            guestBotCallerId: nil,
            hasTimestampedMedia: false,
            id: id,
            importInfo: nil,
            interactionInfo: interactionInfo,
            isChannelPost: false,
            isFromOffline: false,
            isOutgoing: isOutgoing,
            isPaidGramSuggestedPost: false,
            isPaidStarSuggestedPost: false,
            isPinned: false,
            mediaAlbumId: TdInt64(mediaAlbumId),
            paidMessageStarCount: 0,
            receiverId: nil,
            replyMarkup: nil,
            replyTo: replyToMessageId.map { replyId in
                .messageReplyToMessage(MessageReplyToMessage(
                    chatId: chatId,
                    checklistTaskId: 0,
                    content: nil,
                    messageId: replyId,
                    origin: nil,
                    originSendDate: 0,
                    pollOptionId: "",
                    quote: nil))
            },
            restrictionInfo: nil,
            schedulingState: nil,
            selfDestructIn: 0,
            selfDestructType: nil,
            senderBoostCount: 0,
            senderBusinessBotUserId: 0,
            senderId: .messageSenderUser(MessageSenderUser(userId: senderUserId)),
            senderTag: "",
            sendingState: sendingState,
            suggestedPostInfo: nil,
            summaryLanguageCode: "",
            topicId: nil,
            unreadReactions: [],
            viaBotUserId: 0)
    }

    // MARK: - Chats

    /// A chat's place in a list. `order` is a `TdInt64`, so any sort must use
    /// `.rawValue` — the wrapper is `Hashable`, not `Comparable`. An `order` of
    /// 0 means "not in this list", i.e. remove.
    public static func position(
        order: Int64,
        isPinned: Bool = false,
        list: ChatList = .chatListMain
    ) -> ChatPosition {
        ChatPosition(isPinned: isPinned, list: list, order: TdInt64(order), source: nil)
    }

    public static func chat(
        id: Int64,
        title: String,
        positions: [ChatPosition],
        lastMessage: Message? = nil,
        unreadCount: Int = 0,
        isMuted: Bool = false,
        type: ChatType? = nil,
        photo: ChatPhotoInfo? = nil,
        lastReadInboxMessageId: Int64 = 0,
        lastReadOutboxMessageId: Int64 = 0,
        draft: DraftMessage? = nil
    ) -> Chat {
        Chat(
            accentColorId: 0,
            actionBar: nil,
            availableReactions: .chatAvailableReactionsAll(
                ChatAvailableReactionsAll(maxReactionCount: 3)),
            background: nil,
            backgroundCustomEmojiId: TdInt64(0),
            blockList: nil,
            businessBotManageBar: nil,
            canBeDeletedForAllUsers: false,
            canBeDeletedOnlyForSelf: true,
            canBeReported: true,
            // Drive the UI from `positions`, never from `chatLists` — the latter
            // says which lists a chat belongs to, not where it sits in them.
            chatLists: positions.map(\.list),
            clientData: "",
            defaultDisableNotification: false,
            draftMessage: draft,
            emojiStatus: nil,
            hasProtectedContent: false,
            hasScheduledMessages: false,
            id: id,
            isMarkedAsUnread: false,
            isTranslatable: false,
            lastMessage: lastMessage,
            lastReadInboxMessageId: lastReadInboxMessageId,
            lastReadOutboxMessageId: lastReadOutboxMessageId,
            messageAutoDeleteTime: 0,
            messageSenderId: nil,
            notificationSettings: notificationSettings(isMuted: isMuted),
            pendingJoinRequests: nil,
            permissions: ChatPermissions(
                canAddLinkPreviews: true, canChangeInfo: false, canCreateTopics: false,
                canEditTag: false, canInviteUsers: false, canPinMessages: false,
                canReactToMessages: true, canSendAudios: true, canSendBasicMessages: true,
                canSendDocuments: true, canSendOtherMessages: true, canSendPhotos: true,
                canSendPolls: false, canSendVideoNotes: true, canSendVideos: true,
                canSendVoiceNotes: true),
            photo: photo,
            positions: positions,
            profileAccentColorId: 0,
            profileBackgroundCustomEmojiId: TdInt64(0),
            replyMarkupMessageId: 0,
            theme: nil,
            title: title,
            type: type ?? (id > 0
                ? .chatTypePrivate(ChatTypePrivate(userId: id))
                : .chatTypeSupergroup(ChatTypeSupergroup(isChannel: false, supergroupId: -id))),
            unreadCount: unreadCount,
            unreadMentionCount: 0,
            unreadPollVoteCount: 0,
            unreadReactionCount: 0,
            upgradedGiftColors: nil,
            videoChat: VideoChat(
                defaultParticipantId: nil, groupCallId: 0, hasParticipants: false),
            viewAsTopics: false)
    }

    /// `use_default_mute_for` makes `mute_for` meaningless on its own — a naive
    /// reader notifies for muted chats. Fixtures spell both out so the mute
    /// resolution logic is actually exercised.
    public static func notificationSettings(isMuted: Bool) -> ChatNotificationSettings {
        ChatNotificationSettings(
            disableMentionNotifications: false,
            disablePinnedMessageNotifications: false,
            muteFor: isMuted ? 2_147_483_647 : 0,
            muteStories: false,
            showPreview: true,
            showStoryPoster: true,
            soundId: TdInt64(0),
            storySoundId: TdInt64(0),
            useDefaultDisableMentionNotifications: true,
            useDefaultDisablePinnedMessageNotifications: true,
            useDefaultMuteFor: !isMuted,
            useDefaultMuteStories: true,
            useDefaultShowPreview: true,
            useDefaultShowStoryPoster: true,
            useDefaultSound: true,
            useDefaultStorySound: true)
    }

    // MARK: - Updates

    public static func newChat(_ chat: Chat) -> Update {
        .updateNewChat(UpdateNewChat(chat: chat))
    }

    public static func newMessage(_ message: Message) -> Update {
        .updateNewMessage(UpdateNewMessage(message: message))
    }

    public static func chatPosition(chatId: Int64, position: ChatPosition) -> Update {
        .updateChatPosition(UpdateChatPosition(chatId: chatId, position: position))
    }

    /// The trap this fixture exists for: TDLib may send `updateChatLastMessage`
    /// **instead of** `updateChatPosition`, carrying its own `positions` array.
    /// Routing it through a different code path than `updateChatPosition` is how
    /// chat ordering silently breaks.
    public static func chatLastMessage(
        chatId: Int64,
        lastMessage: Message?,
        positions: [ChatPosition]
    ) -> Update {
        .updateChatLastMessage(UpdateChatLastMessage(
            chatId: chatId, lastMessage: lastMessage, positions: positions))
    }

    public static func sendSucceeded(message: Message, oldMessageId: Int64) -> Update {
        .updateMessageSendSucceeded(UpdateMessageSendSucceeded(
            message: message, oldMessageId: oldMessageId))
    }

    public static func fileUpdated(_ file: File) -> Update {
        .updateFile(UpdateFile(file: file))
    }

    public static func authorizationState(_ state: AuthorizationState) -> Update {
        .updateAuthorizationState(UpdateAuthorizationState(authorizationState: state))
    }

    public static func connectionState(_ state: ConnectionState) -> Update {
        .updateConnectionState(UpdateConnectionState(state: state))
    }
}
