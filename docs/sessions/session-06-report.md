# Session 6 — Telegram Desktop parity (report)

Branch `session-06-telegram-parity` (off `session-04-ux-fixes` @ b3f2471),
2026-08-26. Brief:
[session-06-telegram-parity.md](session-06-telegram-parity.md).

**Status: built; T1 verified live, T2 code-complete with L3 pending.**
The founder began actively using the machine mid-session (composing a
message in the panel), so pointer-driven probes were suspended after M5 —
see "Verification still pending" below. Not merged to `main`; not yet
installed (a relaunch would eat an in-memory draft while the founder is
typing).

## Complaint → root cause → outcome

| # | Complaint | What it actually was | Outcome |
| --- | --- | --- | --- |
| C1 | "Clicks on chat folders only register on the text/badge" | Not the chat rows (probe matrix over whitespace/padding/avatar all registered — c34a49a's fix holds). It was the **folder tabs**: an unselected tab has a `.clear` background and a `.plain` Button hit-tests only opaque pixels, so tabs were clickable on their glyphs and unread badge alone — while the selected tab (opaque tint) took clicks anywhere. | Tabs fill the strip height and carry an explicit `contentShape`; the 13 pt profile/settings glyphs got 24 pt hit frames. Verified live: the same padding click that missed on the old build selects the tab on the new one (`tab-padding-prefix/postfix.png`). |
| C2 | "Click quickly through chats and it lands mid-chat; it should go to the first unread / the bottom / where I left" | `ConversationView` was **reused** across chat switches (right pane keyed on `activePane` only): chat A's scroll offset and `isNearBottom` leaked into chat B, and the open-at-bottom anchor never re-fired. No scroll memory existed; `lastReadInboxMessageId` never reached the UI. | View keyed per chat id. Open order per Telegram: saved position → first unread (history loaded *around* the boundary, «Непрочитанные сообщения» ("Unread messages") divider in the upper third) → bottom. Scroll memory in `PanelSharedState` (in-process). Read receipts now follow rows actually seen (debounced `viewMessages`), so the divider cannot lie. Verified live: A-scrolled → B opens at ITS bottom → back to A restores the exact place (`m5-*.png`). D42. |
| C3 | "Super-fast scrolling crashes; media pile up in memory" | **The crash was not memory.** SwiftUI's `VideoPlayer` (`_AVKit_SwiftUI`) aborts the process on macOS 26.6 while instantiating its view metadata the moment a GIF bubble materialises mid-scroll (`failed to demangle superclass of VideoPlayerView`). Reproduced by stress, crash log in hand. Memory was *also* unbounded: scroll-back never trimmed (`trimLiveOverflow` only ran on live appends), one AVPlayer per GIF with no cap, `FileStore` never evicted, no disk rotation. | `PlayerLayerView` (bare `AVPlayerLayer`) replaces `VideoPlayer` everywhere (D41); inline players capped at 4. Window slides both directions at 1500 rows (`hasMoreNewer` + `loadNewer`/`reloadLatest`); `FileStore` LRU-sweeps past 2048 boxes; image caches got count limits + memory-pressure flush; TDLib `optimizeStorage` (8 GB / 30 d) once per launch. Stress: 20 rounds of synthetic scroll-back + `loadOlder` — old build died mid-run, new build survives with RSS flat ~267 MB. |
| C4 | "Media are scattered as separate messages; it needs a collage post" | Albums were entirely unimplemented — the only `mediaAlbumId` reference was a fixture field; f5cf99e's "grouped bubbles" is sender-run corner grouping. | Consecutive same-`media_album_id` photo/video messages collapse into one mosaic post (tdesktop-flavoured row patterns, rows fill the width exactly, aspect-clamped), one bubble, one caption, one meta line. Grouped documents stay stacked bubbles like Telegram. Unit-tested (grouping + layout arithmetic). |
| C5 | "Media download and open in the computer's previewer — they should open inside the window" | Six `NSWorkspace.open` call sites; photos even opened the ~320 pt display-size file. | In-panel viewer: gallery over the loaded window, chevrons + counter, photos at largest size (double-click zoom), videos via `PlayerLayerView` with play/pause. Esc closes the viewer first (D39 chain); the panel holds itself open while the viewer is up; swipe-back ignores gestures over it. |
| C6 | "Video messages don't play at all; finish voice messages; transcription, if there is an endpoint" | Video notes were a static circle that opened Preview.app. Transcription existed server-side all along: TDLib 1.8.66 ships `recognizeSpeech` (Premium-gated, weekly free trial). | Round messages play inline in the circle, with sound; click toggles; finished notes replay. The →A pill fires `recognizeSpeech`; results stream back through `updateMessageContent` (pending → text/error) into the bubble; the Premium gate explains itself in Russian. Voice notes keep their measured `AVAudioPlayer` path. |
| C7 | "The avatar at the top of the chat gets stuck — someone else's, on every chat" | Two bugs: `MediaImage.decoded` (`@State`) survived URL changes on view reuse (stale photo wins forever), and `MinithumbCache` keyed on `count + prefix(16).hashValue` — all TDLib minithumbnails share their first bytes, so equal-length payloads collided. | Decode task resets/repopulates per key and drops post-cancellation results; minithumb keys hash the full payload. Unit-tested (collision repro with padded PNGs). Verified live: chat A ↔ chat B headers each show their own photo (`header-chat-a/b.png`). |
| C8 | "The window sticks open after ordinary clicking through chats" | Session 4's one `pinnedHost` latch: five uncoordinated writers, none released on view teardown; and focus pins had **no natural release at all** — one click into search meant the panel never auto-closed again. | Reason-scoped holds (D40): one owner per reason, cleared on falling edge AND `onDisappear`; holds keep, never summon; a click outside every field ends editing (send re-focuses the composer, Telegram-style); focus holds expire after 20 s of pointer-out silence; bridge `collapse` is the universal unstick; `DebugStatus` reports `activePins`. Verified live: search-click pins → row-click unpins → pointer-away folds; walk-away expiry at t+23 s; the phantom-window repro stays green. |

## Verification

- L1: `make test` green at every milestone — **109/109** at session end
  (98 inherited + 11 new: minithumb collisions, sliding window, album
  grouping/layout).
- L3 (real account, headless CGEvent + DebugBridge, evidence in
  `.artifacts/s6/`, kept locally and not published): click matrices (rows pre-fix, tabs pre/post-fix),
  header avatar A/B, open-at-bottom / scroll-up / switch / restore cycle,
  pin probes incl. 23 s expiry, phantom-window repro, fast-scroll stress
  with RSS sampling (crash repro'd on old build — `NotchGram-2026-08-26-
  125808.ips` — and survived on new).

### Verification still pending (founder became active at the machine)

- Unread-divider landing on a real unread chat (mechanism unit-covered;
  the live probe was interrupted — the pointer probes were literally
  fighting the founder's own cursor).
- Album mosaic, viewer, video-note playback and transcription on the real
  account (code-complete, build green; need one relaunch, which would
  currently eat the founder's in-memory draft).
- Release install (`make install`) — same reason.

## Deviations from the brief

- The brief's C1 hypothesis (chat rows) was wrong — rows were already
  correct; the real offender was the folder tabs. The probe matrix is what
  caught it.
- The crash hypothesis (RAM) was wrong — it was an AVKit_SwiftUI runtime
  abort. The memory bounds were still built (they were real, just not the
  crash).
- T2 scroll memory landed *inside* M5 rather than as a later stretch.

## Debt

- Album posts don't render reactions; their context menu is caption-copy
  only.
- Viewer: no scrubber/seek, no pinch zoom (double-click 2× only), no
  save-as. Photo original beyond the largest PhotoSize not fetched.
- Video note `isPlaying` can desync at natural end (needs a second click
  to restart — no end-of-item observer yet).
- A GIF bubble denied by `InlinePlayerBudget` doesn't retry until it
  rescrolls into view.
- Folder selection was observed to reset to another tab once during live
  probing (suspect `updateChatFolders` re-baseline); unreproduced, watch.
- `hasMoreNewer` interacts with `defaultScrollAnchor(.sizeChanges)` via
  `lastPageDirection` — one-frame ordering is theoretically racy; watch
  for a visible jump when paging downward.
- Scroll memory is in-process only (a relaunch forgets positions) — fine
  for a panel that lives for weeks, revisit if quit/relaunch becomes
  common.

## Addendum — founder's acceptance pass (same day)

Verdict: "more or less happy with everything, it got better", with three findings,
all fixed and re-shipped (`ddc1854`):

- **Viewer cropped portraits** ("it zooms in so that the top and
  bottom edges get cut off"): the blurred minithumbnail stand-in drew `.fill`, and
  nothing sharp appeared until the *largest* photo size finished
  downloading — so the visible thing was a cropped blur. Letterboxed now,
  with the largest already-downloaded size shown fitted immediately.
- **Scroll memory "teleported" chats upward** while rapidly clicking
  through the list: leaving a chat before its layout settled at the bottom
  saved a bogus top anchor, and every later open restored it —
  self-reinforcing. Memory now only trusts visits longer than 2 s.
- **No follow-to-bottom on new messages** ("it doesn't stick to the bottom"): the
  direction-keyed size-change anchor (first cut of D42) flipped to `.top`
  on every live append, killing the glue. Anchor is now keyed on
  `hasMoreNewer` only; an own send always lands at the bottom, incoming
  follows while the reader is already there.

These close C2/C5 to the founder's satisfaction pending their re-check.
The pending L3 items above (albums/viewer/notes screenshots for the
artifact trail) remain, as does `make install`.

## For the next session

Session 3 (multi-account) remains next and re-baselines against this
report. Before it: finish the pending L3 items above (one `make run` when
the founder is away from the machine), `make install`, founder acceptance
pass → merge + `v0.1.0`.
