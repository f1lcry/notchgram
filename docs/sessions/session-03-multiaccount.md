# Session 2 — brief (→ v0.2.0)

Re-baselined against [session-01-report.md](session-01-report.md) on 2026-08-23,
at the end of Session 1.

## Before anything else: finish Session 1

Session 1 stopped at M10 because the acceptance checklist needs a signed-in
account and Telegram's test DC cannot provide one (D29). **Session 2 opens by
closing that**, not by starting new work:

1. The founder's three actions from `.artifacts/CHECKPOINT.md` — sign in, allow
   notifications, reconnect the external displays.
2. The L4 real-account probe and the `v0.1.0` acceptance checklist.
3. `make release`, tag `v0.1.0`.

Only then does the multi-account work below begin. Treat the list under
"Carried over" as part of that closing pass — every item is written or nearly
written, and none of it was verifiable unsigned-in.

## Carried over from Session 1

| Item | State | Note |
| --- | --- | --- |
| Reply-to + context menu (copy / edit own / delete for me / for all) | **not built** | Gate on `messageProperties`, and set the panel pin from the action that *presents* the menu — menu tracking runs a nested runloop the hover poll ignores, so the panel would otherwise collapse out from under an open menu. |
| Drag-and-drop onto the **collapsed** notch | **not built** | `ignoresMouseEvents` is true while collapsed, so `.onDrop` is dead there. The fix is boring.notch's `DragDetector`: global mouse monitors plus `NSPasteboard(name: .drag).changeCount` to force-expand. Dropping onto the *expanded* panel already works. |
| Media **sending** (attach / paste / drop) | built, unverified | Needs an account. Verify photo and document, both directions. |
| Search | built, unverified | Needs real chats. |
| Notifications (D21) | built, unverified | Blocked on the founder allowing notifications; then verify mute resolution and cross-restart dedup. |
| Chat folders as tabs | built, unverified | Needs an account with folders. |
| Multi-display behaviour | fixture-verified only | The largest untested surface. Panel per screen, single expanded host, hot-unplug rebuild debounce, D22 coverage. |
| Real `updateNotificationGroup` path | deferred by D21 | Gives cross-restart dedup, remote dismissal, mention grouping and `show_preview` for free — replaces the hand-rolled notifier. |
| Animated stickers (TGS) | deferred (T3) | Gzipped Lottie; needs a renderer. `webm` stickers are unplayable on macOS 26 (no matroska UTI) and fall back to their thumbnail. |
| Voice **recording** | deferred (T3) | Playback is done. |
| Reactions, forwarding, link previews, mute controls, archived chats | deferred (T3) | Original stretch order. |

## Session 2 proper — multi-account → v0.2.0

The day-1 indirection is already in place: `AccountRegistry` with per-account
database directories and Keychain keys, `TDLibClientManager` as a process-wide
singleton with one client id per account, and test-DC accounts modelled as
ordinary accounts (D9). Session 2 is therefore additive.

- Parallel `TDClient`s over the existing registry; one update drain loop per
  account, each feeding its own repos.
- Add-account flow reusing the M4 auth UI unchanged.
- Fast switching that beats official Telegram: avatar strip + ⌘1…⌘9 + a cycle
  hotkey.
- Per-account and aggregate unread badges, feeding the collapsed-notch badge
  (D10) when it is switched on.
- Per-account notifications, with the account visible in the banner.

### Things Session 1 learned that Session 2 must not rediscover

- **Never `TDLibClientManager.closeClients()`** — it busy-waits from a `deinit`.
  Shut each client down individually with a deadline (D28), and never use the
  async `close()`.
- **Every TDLib request needs a deadline** (D26). A request to an unreachable
  data centre never answers *and* never errors, and the continuation cannot be
  cancelled.
- **Keychain access is async and off the main actor** (D32), and items must keep
  the permissive ACL or the second code signature gets a dialog.
- **Updates are handled in order, in one loop.** A `Task` per update silently
  reorders them and corrupts chat order and counters.
- `docs/reference/tdlibkit-api.md` is the authority for TDLibKit call shapes,
  including the "Verified initialisers" section at the end. The generated field
  lists earlier in that file are approximations.
