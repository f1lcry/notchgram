# Session 4 — Shell & data-layer fixes (brief + report)

Branch `session-04-ux-fixes` (off `session-02-stabilize-ux`), 2026-08-24.
Founder-initiated by voice brief, no pre-written contract — like Session 2,
this document is both the reconstructed brief and the report.

**Status: shipped and installed.** The `/Applications` copy is the new
Release build. Not merged to `main` (no brief authorizes it); `v0.1.0`
remains untagged pending the founder's acceptance pass.

---

## The founder's complaints (translated from Russian) → outcome

| Complaint | Root cause found | Outcome |
| --- | --- | --- |
| "It stopped opening — only a notch tab off to the side shows up, and nothing happens"; "it moved off-centre, on the external monitor too"; "the notch tab slides left and the panel unfolds from the left" | One bug, three symptoms: Session 2's chrome aligned the slab to the window's **leading edge** (`ZStack(.topLeading)` + offset by the *expanded* panel's minX). The collapsed tab painted at the expanded panel's left edge — ~390 pt left of centre — while the hover trigger stayed correctly centred: the visible tab was not hoverable, and expansion grew rightwards out of the misplaced tab | Slab is centre-aligned on the anchor axis (D36); collapsed tab, trigger and expansion share one axis by construction. New unit test `testPanelIsCentredOnTheAnchorAxis` guards it. Verified by pointer probe on both screens: warp onto the tab → `expanded`, warp away → `collapsed` |
| "Get rid of the mushroom system — just let the window drop down normally, with a normal animation, like Dictate" | The mushroom (stem/cap outline + menu-bar carve-outs) was Session 2's answer to a complaint that only existed because the frozen panel could never collapse | Mushroom deleted: `NotchSlabShape` is now Dictate's two-radius top-filleted rectangle; carve-outs and `capTop`/`stemWidth` geometry removed. The open panel may cover the middle of the menu bar — it is transient (founder's explicit call). Same 0.38 s/0.86 spring, now growing symmetrically out of the centre |
| "Folders are jumbled, pinned chats don't sync, some chats are missing" | `ChatOrderIndex` treated a positions array that does not mention its list as **removal**. `updateChatPosition` carries exactly one list's position, so every main-list bump drained the folder indexes and vice versa; empty arrays (`updateChatLastMessage` with unchanged positions) drained everything | Absence now means untouched; leaving a list happens only via explicit `order == 0` (matching TDLib's contract). Folders load eagerly on `updateChatFolders`, folder rows use the folder's own pinned set, folder tabs show Telegram's unmuted-unread badge, «Все чаты» ("All chats") is localized, end-of-list paging pages the selected folder, tab strip auto-scrolls to the selection. Verified live: Personal tab renders exactly the pinned chats, badges live-update |
| "Search doesn't work — it needs a full implementation, like in Telegram" | Two independent bugs. (1) **No text field in the panel ever accepted a keystroke**: `becomesKeyOnlyIfNeeded` never fires for SwiftUI text fields, and SwiftUI refuses focus-by-click while the app is inactive — clicks landed, panel stayed non-key, keystrokes went to the previously-key app. (2) Server search results were resolved against the *visible main list* only, so everything the server found beyond it was silently dropped | (1) `NotchPanel.sendEvent` takes key on mouse-down and focuses the editable AppKit text view under the click itself (D37) — fixes search, composer and auth fields alike. (2) Ids resolve through the repo-wide summary cache; `searchPublicChats` (usernames) extends the chat section; global `searchMessages` fills Telegram's «Сообщения» ("Messages") section rendered as chat rows with the found message as preview; remote passes run concurrently, generation-guarded, best-effort offline. Verified by CGEvent probe: click → field editor focused, Cyrillic lands in the query; bridge `search` command shows local + server + public results |

## What else changed

- **DebugBridge**: `search`, `selectFolder`, `focusSearch` commands;
  `focusedField` now reports the real first-responder type and
  `focusedFieldText` mirrors the live search query. Every state this
  session's verification used is reachable headlessly, per the standing
  invariant.
- `ClientView` opens conversations from the summary cache, not the visible
  main list — a chat opened from search results or a folder-only chat now
  actually opens.
- Docs: D36/D37 added, D33's mushroom paragraph superseded in place.

## Verification evidence (`.artifacts/s4/` — kept locally, not published)

- L1: `make test` **97/97** after each slice (four commits, four green runs).
- L3/L4 combined, against the founder's real account, driven end-to-end by
  DebugBridge + CGEvent probes with no human at the keyboard:
  - `collapsed-ext.png` — collapsed tab centred on the external display;
  - `expanded-ext.png` — centred dropdown, folder tabs with unread badges
    («Все чаты 6», «Personal 2»), pinned rows, RU chrome;
  - hover probe: warp onto the drawn tab → `expanded`; onto the physical
    notch → `expanded`; away → `collapsed` (the exact flow that was dead);
  - `search.png` — «Чаты» ("Chats") section with local + server + **public** results
    for «телеграм» (public finds were previously impossible);
  - `folder-2.png` — folder tab membership matches Telegram;
  - typing probe: click into the search box → `_SystemTextFieldFieldEditor`
    is first responder, typed «тест» arrives in the query, panel stays open
    throughout (8 s watch), frontmost app unchanged.
- Release smoke: installed `/Applications` copy launches, hover works.

## Debt / not done

- Message-search hits open the chat, not the specific message (no
  scroll-to-message yet).
- Search sections are not paginated (`nextOffset` unused); no recent-search
  history; no contacts-only filter chips.
- The stray-character artifact seen once during synthetic typing (`«ся»`
  prefix) did not reproduce and physical typing is unaffected; watch for it.
- Interaction pinning while editing relies on SwiftUI noticing the
  AppKit-driven focus (it did in probes); if a collapse-while-typing report
  ever comes in, pin from `NotchPanel.sendEvent` directly.
- Session-1/2 leftovers unchanged: reply-to, edit/delete context menu,
  stickers/voice/GIF live exercise, auth screens English-first.

## Addendum — same-day follow-up (Session 5 scope, same branch)

Founder's second pass on the installed build: the open panel "looks cut off
again", the shadows should not exist at all, and hover still intermittently
failed to expand. Directive: take Dictate's window/shadow/animation/hover
model wholesale instead of re-deriving it.

Done, verbatim from Dictate's source: window frame **is** the panel (the
72 pt shadow margin is gone — it was the thing reading as "cut off"), no
drawn shadow / stroke / glass (plain black slab), single 150 ms dwell,
Dictate's trigger slop (±6 pt, 6 pt under a drawn tab, 4 pt overhang),
coverage orders a covered tab out instead of alpha-juggling it (pinned
hosts excepted for D22). The margin hit-test carve-up and the screenshot
slab-crop went away with the margin. Kept deliberately non-Dictate: D37
click-to-focus (Dictate has no text input), pinning, mount/unmount.

Verified: 97/97 unit; hover expand/collapse via pointer probe on both
screens; desktop capture shows a flat, seamless slab (`noshadow-crop.png`);
click → type «тест» lands in the query; Esc releases focus and the panel
folds. Hover-flakiness had no reproducible cause in this run — the port
removes most of the state surface that could have caused it (coverage
chrome, oversized-window hit-testing); if it recurs, capture
`debug-bridge.sh status` at the moment it refuses.

Third founder pass, same day:

- **Content really was clipped** — by the ported shape itself:
  `NotchSlabShape`'s body runs at `x = topRadius` (11 pt) below the top
  flare, so it is narrower than its rect everywhere but the very top edge;
  content laid out to the full rect lost exactly 11 pt per side to the clip
  (avatars shaved, search box flush). Dictate masks this with 14 pt content
  padding — ported the padding too: the chrome now insets content by the
  side radius (11 pt) plus 10 pt at the bottom to clear the corner arcs
  (`inset-fix.png`).
- **Upload latch** (Dictate's "latched while dictating"): the panel pins
  itself open while any outgoing message is still `.pending` — a file
  mid-upload no longer folds away when the pointer leaves
  (`MessageRepo.hasPendingOutgoing` → `setInteractionPinned`).
- **One file picker at a time**: `NSOpenPanel.begin` is non-modal, so every
  extra paperclip click stacked another dialog; guarded by state, and the
  panel stays pinned for the picker's lifetime (choosing a file means the
  pointer leaves the panel by definition), unpinning back to the composer's
  focus state on close.

Fourth founder pass, same day:

- **The "phantom window"** (panel stops opening after cancelling the file
  dialog; clicks near the notch feel eaten): the Session-5 Dictate coverage
  port was the culprit. When `FullScreenProbe` read a display as covered,
  the tab was ordered out **and the poll skipped the host** — a live
  trigger zone with an invisible, unopenable panel, stuck until coverage
  flapped back. Coverage is now demoted to exactly one effect: the
  collapsed tab's alpha. The window stays ordered in, the pointer is always
  tracked, hover and force-expand summon the panel over fullscreen (D22
  restored, stronger than before). The probe also ignores this app's own
  windows (a file dialog must never read as "the display is covered").
- **Black bars**: the open slab is no longer raw black — it fills with the
  theme's `panelShell` (tdesktop night navy), so the menu-bar strip and the
  content gutters read as one surface with the UI; collapsed it stays pure
  black to read as the notch (`shell-color.png`).
- **File dialog under the panel**: the picker now opens at the notch
  panel's window level, parked just below it (clamped to the visible
  frame), so nothing overlaps and nothing needs dragging.

Fifth founder pass (2026-08-25):

- **The phantom window, round two** (after acting in the panel — a message
  sent, an attach attempted — hover stops opening it; clicks in the zone
  where the panel would be are eaten by something invisible): not the
  coverage probe this time. On macOS 26, the `.scrollPosition(_:)` binding
  on the conversation's message list, caught inside the fold animation,
  wedges SwiftUI's render loop for the whole process — bodies keep
  evaluating (verified by lldb breakpoint) but nothing paints again, on any
  display, and even a full `rebuild()` of every window does not recover.
  The hover state machine keeps running underneath, so the panel sits at
  `ignoresMouseEvents = false` with pixels frozen collapsed — exactly the
  reported symptom. Reproduced 100% headlessly (`expand → openChat →
  collapse → expand` via DebugBridge, screencapture of the panel window),
  bisected to the binding alone. Fix (D38): `ScrollViewReader` + a bottom
  sentinel row for scroll-to-bottom, `defaultScrollAnchor(.bottom)` for
  `.initialOffset` (open at newest) and `.sizeChanges` (reader keeps their
  distance from the bottom while history pages prepend). Verified: repeated
  headless cycles and pointer-driven hover cycles on both displays all
  repaint; open lands at the newest message; 97/97 unit tests.

Sixth founder pass (2026-08-25, after the ScrollPosition fix):

- **Duplicated outgoing message** (one copy stuck on the clock, one
  confirmed; reopening the chat cleared it): a race in the send pipeline.
  TDLib echoes an outgoing send as `updateNewMessage` (pending state,
  temporary id) and that echo can outrun the `sendMessage` response — at
  which point the temporary id is not yet bound, so `merge` inserted the
  echo as a second row beside the optimistic one. The echo carries the
  correlation token in `messageSendingStatePending.sendingId`; `merge` now
  folds it into the optimistic row, and `sendText` drops any stray row
  under the temporary id as a second line of defence. Covered by
  `testLocalEchoBeforeSendResponseDoesNotDuplicateTheRow`.
- **Esc steps back** (D39): release keyboard focus → leave
  settings/profile → close the open chat, one level per press. Esc is
  routed in `NotchPanel.sendEvent` by key code (nothing synthesises
  `cancelOperation` without a field editor, and the hosting view swallows
  bare keyDown). `becomesKeyOnlyIfNeeded` turned off: it resigned the
  window server's key focus on every non-text click, sending Esc and
  typing to the previously active app; first-click behaviour verified
  unharmed (non-activating panel never swallows clicks on activation).
- **Swipe-back** (D39): a horizontal two-finger swipe (Magic Mouse or
  trackpad) over the conversation pane closes the chat — phased
  `scrollWheel` deltas, 60 pt of dominant horizontal travel, either
  direction; ignored over the chat list.

Verified: 98/98 unit; pointer-driven pass — first click on a row opens the
chat, canvas click keeps key, one Esc closes the chat and an extra Esc is a
no-op, swipe closes over the conversation and not over the list; the
ScrollPosition phantom repro stays green after the changes.

## For the next session

Session 3 (multi-account) remains next in line and re-baselines against this
report. Before it: founder's M10-style pass on this build; if green, merge
per that pass and tag `v0.1.0`.
