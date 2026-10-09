# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/f1lcry/notchgram/security/advisories/new)
(Security tab → *Report a vulnerability*). Do not open a public issue.

Include what you found, how to reproduce it, the NotchGram and macOS versions,
and the impact you expect. You should get a first reply within a week. Fixes
ship as a new release through the usual update channel.

Never include real account data, session files, phone numbers or chat content
in a report.

## Scope

In scope: the NotchGram app and this repository, including the build and
release scripts.

Out of scope, please report upstream:

- TDLib and the MTProto protocol: <https://github.com/tdlib/td>
- TDLibKit / TDLibFramework: <https://github.com/Swiftgram/TDLibKit>
- Sparkle: <https://github.com/sparkle-project/Sparkle>
- Telegram's servers and accounts: <https://telegram.org/faq#q-what-can-i-do-if-i-find-a-bug>

## Notes for researchers

- Local data is TDLib's database under
  `~/Library/Application Support/NotchGram/`, encrypted with a per-account key
  kept in the user's login Keychain. The Keychain item's access list
  deliberately trusts any application, so Debug and Release builds (signed
  with different certificates) can both read it without a prompt. That
  trade-off is documented as D32 in `docs/ARCHITECTURE.md`; the key protects
  a database stored next to it under the same user account.
- The app contains a DebugBridge: an HTTP control channel on a Unix domain
  socket at `~/Library/Application Support/NotchGram/debug.sock`, used for
  automated testing. It exists in Debug builds only: it is compiled out of
  Release builds (the ones published as releases), and `make verify-release`
  fails if any of it reaches the Release binary (D43). In a Debug build it is
  inert unless enabled with
  `defaults write com.f1lcry.notchgram DebugBridgeEnabled -bool YES` or the
  `NOTCHGRAM_DEBUG_BRIDGE=1` environment variable; `make run` and the Xcode
  scheme enable it. Only processes running as the same user can reach the
  socket.
