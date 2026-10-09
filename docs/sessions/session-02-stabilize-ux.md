# Session 2 — Stabilization & UX (brief + report)

Branch `session-02-stabilize-ux`, 2026-08-24. Founder-initiated by voice brief
(no pre-written contract): the Session-1 build froze in daily use and read as
an alpha. This document is both the reconstructed brief and the report.

**Status: shipped and installed.** The `/Applications` copy is the new Release
build; the founder's next hover gets everything below. `v0.1.0` remains
untagged — the M10 acceptance checklist still needs the founder's pass
(CP2-style), now unblocked.

---

## The founder's complaints (translated from Russian) → outcome

| Complaint | Root cause found | Outcome |
| --- | --- | --- |
| App froze while scrolling a chat, stayed a zombie holding the panel open; Activity Monitor showed **10–13 GB** and Not Responding | Livelock, not deadlock: `sample` showed the main thread at 100 % inside SwiftUI layout (`SelectionOverlay`/`NSTextField` churn). Four compounding causes: rows keyed by array **offset** (every update re-diffed every row), the load-older spinner's `onAppear` chain-loading the entire history, `MessageRepo` publishing one SwiftUI transaction **per message** per page, and every photo re-decoded from disk at full resolution on every body pass, uncached | Fixed: identity-stable rows, load cooldown, batched single-publish merges, 1500-row live cap, downsampled `ImageCache`, per-file observable `FileBox` (progress ticks no longer invalidate the whole UI), cached date formatters, `textSelection` replaced by context-menu Copy. Measured after: **~200 MB** under the same scroll-back load, **89 MB** idle Release |
| Expanded panel blocks the menu bar; "the unfold system is buggy" | Two things: the frozen app could never collapse, and the expanded slab really did paint a full-width black band over the menu bar | The livelock is gone, and the slab is now a **mushroom**: above the menu-bar line only the stem (notch/tab) paints, the wide body starts below it. Menu bar visible and clickable on both flanks (carve-outs retained). Verified by pointer probe: hover → expand, move away → collapse |
| Ugly "cut-out" shadow with a visible seam | The window was exactly the slab's size; the SwiftUI shadow (and the spring's overshoot) clipped at the window edge | Window now carries a 72 pt transparent margin (Dictate's oversized-window trick); two-layer shadow (wide ambient + tight contact) blurs freely. Margins are click-through via hit-test |
| Panel content "cut off" | Same window-exactly-slab-size bug: mid-spring overshoot clipped the content; plus the capture path cropped wrong | Content lays out at full panel size at all times and is clipped/faded by the shape (never reflows); screenshot crop fixed (flipped coords) |
| First click from another app does nothing, second click works | `becomesKeyOnlyIfNeeded` was missing — click #1 was spent making the panel key | Added (plus `acceptsFirstMouse` on the hosting view). Verified by CGEvent probe: **one** synthetic click on a chat row opened it while Ghostty stayed frontmost |
| "Message" composer shown in channels where posting is forbidden | Permissions were never modelled | `canSendMessages` from chat permissions + own member status (`updateSupergroup`): channels get Telegram's footer with a working mute/unmute toggle, restricted groups get a "posting is restricted" bar, admins with `canPostMessages` keep the composer |
| Media "don't work" | Written in Session 1 but never run against real data; also every image decode was pathological (see freeze) | Live-verified this session: photos download and render inline, video posts show thumbnail + duration and download-with-progress → open externally, round **video notes** render as circles (new), reactions render as chips (new), captions, documents with progress. Stickers/voice/GIF code paths went through the same cache rework but were not exercised live — no such message was in reach |
| English preview labels inside Russian chats; alpha-looking messages overall | — | Full RU localization behind an `AppLanguage` default (**default: ru**; Settings has a language switch), RU date locales («Ср», «26 марта»), tdesktop night palette over glass, grouped bubble corners, sender-name colors, avatars in group chats, ✓/✓✓ read marks, time-on-media scrim, hover states, scroll-to-bottom button, pane-switch fade |

## What else changed

- **Liquid Glass**: the slab's body renders over an always-active
  behind-window blur (`GlassBackdrop`) under a dark tint; surfaces in the
  theme are translucent by design, bubbles/badges stay opaque for legibility.
  Collapsed the slab is still pure black — it must read as the notch.
- **DebugBridge** gained `openChatAt` (open the Nth row of the live list) and
  `loadOlder` (pull history pages) — the tools this session's real-data
  verification ran on.
- Session-1 geometry semantics kept: `NotchGeometry.panel` still means the
  slab; the NSPanel frame is the new `window`. All 97 unit tests pass
  unmodified except through the public-API additions.

## Verification evidence (`.artifacts/s2/` — kept locally, not published)

- L1: `make test` **97/97** (twice: mid-session and final).
- L3/L4 combined, against the founder's real account:
  - chat list renders live (RU labels, folder tabs, muted badges);
  - `openChatAt` on a real group: history loads, photo renders, sender
    colors/avatars/grouping correct — `chat-open2.png`;
  - busy channel: reactions chips, channel footer with mute toggle, subtitle
    «канал» ("channel") — `channel.png`; round video note — `videonote.png`;
  - `loadOlder` ×12 on a group and ×15 on a media channel: RSS flat at
    ~200 MB, UI responsive throughout (the Session-1 build died exactly here);
  - pointer probe (uidrive): hover-expand on the physical notch →
    `expanded`; **single** click on a row while Ghostty frontmost →
    `openChatId` set, frontmost unchanged, panel key; pointer away →
    `collapsed`;
  - desktop screenshot of the expanded panel on an external display:
    menu bar visible on both flanks, stem tab, soft unclipped shadow —
    `disp2.png`;
  - Release smoke on the installed `/Applications` copy: ready, open, stress,
    collapse — `release-final.png`, 89 MB idle / 145 MB after stress.

## Debt / not done

- **No message was sent** this session (nothing verified for send since
  Session 1) — deliberate: no noise into real chats. Founder: send a text +
  photo to Saved Messages as part of the M10 pass.
- Stickers (webp render, tgs/webm thumbnail fallback), voice playback and GIF
  autoplay: reworked but not exercised live.
- Scroll feel (`ScrollPosition` + `scrollTargetLayout`, prepend anchoring,
  follow-if-near-bottom) verified by data stress, not by a physical wheel.
- The cap's shadow bleeds slightly above the menu-bar line at the corners;
  visible only in in-app captures, judged fine on the desktop.
- Reply-to, edit/delete context menu, drag onto the collapsed notch — still
  the Session-1 leftovers, now Session 4 candidates.
- `AppLanguage` strings resolve once at launch (static tables) — language
  switch needs relaunch, and the Settings pane says so.
- Auth screens and Profile remain English-first.

## For the next session

Multi-account is renumbered to
[session-03-multiaccount.md](session-03-multiaccount.md). Before it: run the
founder M10 pass on this build and tag `v0.1.0` if green.
