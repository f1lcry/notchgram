@preconcurrency import TDLibKit

//
// D23 — the entire Swift-6 story for TDLibKit, in one file.
//
// TDLibKit declares `swift-tools-version:5.3`, so the package itself compiles in
// Swift 5 mode and builds clean. A grep for `Sendable|@unchecked|nonisolated|
// @MainActor` across its sources returns **zero** matches, which means all the
// friction is at NotchGram's call sites and none of it is inside the package.
//
// Every type below is a `struct` or an `indirect enum` whose stored properties
// are themselves value types (String, Int, Int64, Bool, Data, TdInt64, arrays of
// the same, and other such enums). They have value semantics and no reference
// interior, so `@unchecked Sendable` here is a statement of fact, not a
// suppression. It is deliberately NOT applied to `TDLibClient` or
// `TDLibClientManager`, which are classes — those never cross an actor boundary
// (see TDLibRuntime and TDClient).
//
// `@retroactive` is required: neither `Sendable` nor these types are ours.
//

// MARK: - Update stream

extension Update: @retroactive @unchecked Sendable {}
extension UpdateAuthorizationState: @retroactive @unchecked Sendable {}
extension UpdateConnectionState: @retroactive @unchecked Sendable {}
extension UpdateNewMessage: @retroactive @unchecked Sendable {}
extension UpdateNewChat: @retroactive @unchecked Sendable {}
extension UpdateChatPosition: @retroactive @unchecked Sendable {}
extension UpdateChatLastMessage: @retroactive @unchecked Sendable {}
extension UpdateChatDraftMessage: @retroactive @unchecked Sendable {}
extension UpdateFile: @retroactive @unchecked Sendable {}

// MARK: - Authorization

extension AuthorizationState: @retroactive @unchecked Sendable {}
extension AuthenticationCodeInfo: @retroactive @unchecked Sendable {}
extension AuthenticationCodeType: @retroactive @unchecked Sendable {}
extension ConnectionState: @retroactive @unchecked Sendable {}
extension PhoneNumberAuthenticationSettings: @retroactive @unchecked Sendable {}
extension EmailAddressAuthentication: @retroactive @unchecked Sendable {}
extension ResendCodeReason: @retroactive @unchecked Sendable {}

// MARK: - Domain values crossed between the transport and the repos

extension Chat: @retroactive @unchecked Sendable {}
extension ChatList: @retroactive @unchecked Sendable {}
extension ChatType: @retroactive @unchecked Sendable {}
extension ChatPosition: @retroactive @unchecked Sendable {}
extension ChatPhotoInfo: @retroactive @unchecked Sendable {}
extension ChatFolderInfo: @retroactive @unchecked Sendable {}
extension ChatNotificationSettings: @retroactive @unchecked Sendable {}
extension ScopeNotificationSettings: @retroactive @unchecked Sendable {}
extension Message: @retroactive @unchecked Sendable {}
extension Messages: @retroactive @unchecked Sendable {}
extension MessageContent: @retroactive @unchecked Sendable {}
extension MessageSender: @retroactive @unchecked Sendable {}
extension MessageSendingState: @retroactive @unchecked Sendable {}
extension FormattedText: @retroactive @unchecked Sendable {}
extension User: @retroactive @unchecked Sendable {}
extension Supergroup: @retroactive @unchecked Sendable {}
extension BasicGroup: @retroactive @unchecked Sendable {}
extension File: @retroactive @unchecked Sendable {}
extension LocalFile: @retroactive @unchecked Sendable {}
extension RemoteFile: @retroactive @unchecked Sendable {}
extension Minithumbnail: @retroactive @unchecked Sendable {}
extension Thumbnail: @retroactive @unchecked Sendable {}
extension PhotoSize: @retroactive @unchecked Sendable {}
extension Photo: @retroactive @unchecked Sendable {}
extension Sticker: @retroactive @unchecked Sendable {}
extension Animation: @retroactive @unchecked Sendable {}
extension VoiceNote: @retroactive @unchecked Sendable {}
extension Video: @retroactive @unchecked Sendable {}
extension Document: @retroactive @unchecked Sendable {}
extension OptionValue: @retroactive @unchecked Sendable {}
extension Ok: @retroactive @unchecked Sendable {}

// MARK: - Request inputs
//
// These cross into `TDClient`'s actor as method arguments, which Swift 6 checks
// just as strictly as return values ("sending 'replyTo' risks causing data
// races"). Same reasoning as above: value types all the way down.

extension InputMessageContent: @retroactive @unchecked Sendable {}
extension InputMessageText: @retroactive @unchecked Sendable {}
extension InputMessagePhoto: @retroactive @unchecked Sendable {}
extension InputMessageDocument: @retroactive @unchecked Sendable {}
extension InputMessageReplyTo: @retroactive @unchecked Sendable {}
extension InputPhoto: @retroactive @unchecked Sendable {}
extension InputDocument: @retroactive @unchecked Sendable {}
extension InputThumbnail: @retroactive @unchecked Sendable {}
extension InputFile: @retroactive @unchecked Sendable {}
extension MessageSendOptions: @retroactive @unchecked Sendable {}
extension MessageTopic: @retroactive @unchecked Sendable {}
extension MessageSource: @retroactive @unchecked Sendable {}
extension ReplyMarkup: @retroactive @unchecked Sendable {}
extension LinkPreviewOptions: @retroactive @unchecked Sendable {}
extension TdInt64: @retroactive @unchecked Sendable {}

// NOTE: `TDLibKit.Error` is deliberately absent. The compiler already infers
// Sendable for it, and restating the conformance is a warning. It still shadows
// `Swift.Error` inside any file importing the module, so our own signatures
// write `Swift.Error` explicitly — see `TDError` for the mapping NotchGram uses.
