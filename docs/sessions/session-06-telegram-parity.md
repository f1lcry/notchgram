# Session 6 — Telegram Desktop parity (brief)

Branch `session-06-telegram-parity` (off `session-04-ux-fixes` @ b3f2471),
2026-08-26. Founder-initiated by voice brief at CP0, no pre-written
contract — like Sessions 2 and 4, this document is the reconstructed brief;
the report is written separately at session end.

Session theme, founder's words: make the app feel **maximally like official
Telegram Desktop** — same behavior, same mechanics, same animations, so that
using it feels like the original.

## The founder's complaints (translated from Russian) → diagnosis (pre-session recon)

| # | Complaint | Recon diagnosis |
| --- | --- | --- |
| C1 | "I want chat folders to be fully clickable — I press inside the button area, but the click only counts on the text/badge; I have to click several times" | `ChatRowView` already ends in `.contentShape(.rect)` under a `.plain` Button (c34a49a) and the shape nominally covers 268×56 — yet clicks on padding still miss. Needs a pointer-probe repro at row whitespace, then a hit-path fix (hoist `contentShape` onto the Button, ensure the label fills the row width). Visual note: `rowBackground` is inset 4 pt per side, so the highlight is 8 pt narrower than the hit rect. |
| C2 | "When I click quickly through chats, it drops me somewhere in the middle of the chat, no telling where. It should work like Telegram: to the first unread; if everything is read — to the very bottom; if I scrolled up myself and left — back to exactly that spot" | Root cause of the random landing: `ConversationView` is **reused** across chat switches (`ClientView` keys the right pane on `activePane`, not chat id), so chat A's scroll offset and `isNearBottom` leak into chat B and `.defaultScrollAnchor(.bottom, for: .initialOffset)` never re-fires. No per-chat scroll memory exists (`PanelSharedState` names it in a comment, never added). `lastReadInboxMessageId` is tracked in `ChatRepo` but not plumbed to `ChatSummary`. `MessageRepo` can only page older — no open-around-message, no newer paging. |
| C3 | "When I scroll a chat super fast, the app can crash; media apparently pile up in memory. It needs proper caching with rotation, like Telegram" | Three unbounded growth paths: (1) `trimLiveOverflow` is called only on `updateNewMessage`, never after paging merges — scroll-back grows past `maxLiveItems` without bound, each item carrying minithumbnail `Data`; (2) one `AVQueuePlayer`+`AVPlayerLooper` per GIF bubble, created/destroyed at scroll speed with no cap; (3) `FileStore.boxes`/`requested` never evict. `ImageCache` has a 192 MB advisory cost limit only. No disk-cache rotation (`optimizeStorage` never called). |
| C4 | "Media files are scattered as separate messages — there is no proper collage post like in Telegram. The system has to be exactly the same" | Albums are not implemented at all: the only `mediaAlbumId` reference in the tree is a fixture field. f5cf99e's "grouped bubbles" is sender-run corner grouping, not albums. |
| C5 | "To open a media file, it downloads to the computer and opens in Preview — inconvenient. Viewing should happen inside the window" | No in-app viewer exists; photos, videos, video notes and documents all go through `NSWorkspace.open`, and photos open the ~320 pt display-size file, not the original. |
| C6 | "Video messages don't play at all — they open as a file on the computer. Bring them up to Telegram's format; voice messages too; add transcription if they have an endpoint" | Video notes render a static circle and open externally. Voice notes have a real in-app `AVAudioPlayer`. Transcription: TDLib 1.8.66 ships `recognizeSpeech` + `updateSpeechRecognitionTrial` (Premium-gated, weekly free trial) — integrable, currently unused. |
| C7 | "The avatar at the top inside a chat gets stuck — it shows another user's on every chat" | Two independent bugs in `MediaImageView`: (a) `MediaImage.decoded` (`@State`) is never cleared when the URL changes or disappears — a reused header keeps the previous chat's photo, and a cached correct photo loses to the stale `decoded`; (b) `MinithumbCache` keys on `count + prefix(16).hashValue`, and all TDLib minithumbnails share the same first 16 bytes — any two of equal byte length collide. |
| C8 | "The window got stuck open — I move the cursor away and it doesn't close; it happened after ordinary clicking through chats" | One un-refcounted `pinnedHost` latch with five uncoordinated writers (composer focus, picker open/close, search focus, pending-outgoing edge), none of which unpins on view teardown; ordinary navigation destroys those views before the releasing edge fires. `rebuild()` also relocates a stale pin to a different host. `shared.isInteractionPinned` is write-only (no reader). |

## Scope tiers

- **T1 — hard requirement (bugs):**
  - C1 full-row clicks, verified by pointer probe at row padding.
  - C2 open behavior: first unread (with unread divider) → else bottom;
    no mid-chat landings on rapid switching.
  - C3 memory: bounded live window on all paging paths, bounded GIF
    players, FileStore eviction, no crash under a fast-scroll stress run.
  - C7 header avatar always matches the open chat.
  - C8 pin system redesigned so ordinary navigation can never latch the
    panel open; DebugBridge exposes pin state.
- **T2 — target (parity features):**
  - C2 scroll memory: leaving a chat scrolled-up and returning restores
    the position (in-process; persistence across restarts not required).
  - C4 album collage: consecutive same-`mediaAlbumId` messages render as
    one Telegram-style mosaic post with a single caption.
  - C5 in-app viewer overlay: photos (full-res, zoom) and videos
    (AVPlayer) open inside the panel; Esc steps back per D39; prev/next
    across the chat's loaded media.
  - C6 video notes play inline in the circular bubble (click to
    play/pause, with sound); voice/video-note transcription via
    `recognizeSpeech` with Premium/trial-aware fallback UI.
- **T3 — stretch:**
  - Waveform seek-by-click; 2×/1.5× playback rate.
  - Disk-cache rotation: periodic `optimizeStorage` with sane defaults.
  - Viewer: download-original button, pinch/scroll zoom polish.

## Milestone order

M1 C7 avatar (smallest, founder-visible daily) → M2 C1 clicks → M3 C8 pin
latch → M4 C3 memory bounds → M5 C2 open behavior + scroll memory →
M6 C4 albums → M7 C5 viewer → M8 C6 video notes + transcription →
M9 verify sweep, report, docs, install.

One commit per milestone minimum, conventional commits, push as we go.

## Constraints carried forward

- D38: never reintroduce a `.scrollPosition(_:)` binding — macOS 26 wedges
  the render loop process-wide. All scroll control via `ScrollViewReader`
  + sentinel rows + `defaultScrollAnchor`.
- D16: hover stays polled; no tracking areas, no `.onHover` for the FSM.
- D34: publish-per-batch discipline; stable row identity; downsampled
  decodes only.
- The phantom-window repro (`expand → openChat → collapse → expand`
  headless) must stay green after every scroll-related change.

## Verification

- L1 `make test` green at every milestone; new units for: scroll-anchor
  bookkeeping, album grouping, minithumb cache keys, pin bookkeeping.
- L3 headless via DebugBridge + CGEvent + `screencapture`:
  - click probe at chat-row padding/badge/whitespace coordinates → chat
    opens on first click;
  - chat-switch avatar probe: open A → open B → screenshot header;
  - open-position probe: unread chat opens at divider; read chat opens at
    bottom; scroll up → leave → return → same position;
  - fast-scroll stress (repeated `loadOlder` + synthetic scroll) with
    memory footprint sampled — flat, no crash;
  - pin-latch probe: focus composer → switch pane → pointer leaves →
    panel folds.
- Evidence to `.artifacts/s6/`, referenced from the session report.

## Pre-authorized by this brief

- Push the session branch; `make install` the Release build at session end
  (same as Session 4).
- **Not** authorized: merge to `main`, tagging (remains the founder's
  acceptance call, CP2).
