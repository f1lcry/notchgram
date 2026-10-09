# NotchGram — Roadmap

Status: **Session 7 (Obsidian redesign) built** (2026-08-26). The
Telegram-blue skin is gone: pure-black glass that merges with the physical
notch (the founder's "the notch reads as a hole in the app"), one ice-cyan
accent, Liquid Glass floats, a shared motion vocabulary — P3's "look like
tdesktop" is superseded; the density stays, the skin is NotchGram's own.
Report: [sessions/session-07-report.md](sessions/session-07-report.md).

Session 6 (Telegram Desktop parity, same day):
the founder's eight parity complaints landed: full-area folder-tab/row
clicks, Telegram open behavior (saved position → unread divider → bottom,
per-chat view identity), the fast-scroll crash killed (it was SwiftUI's
`VideoPlayer` aborting the process, D41 — plus every media memory path is
now bounded, D42), album mosaics, an in-panel photo/video viewer, inline
round-message playback with Telegram transcription, avatar-bleed fixed
(stale `MediaImage` state + minithumb cache key collisions), and the
stuck-open panel replaced by reason-scoped holds with focus expiry (D40).
Brief: [sessions/session-06-telegram-parity.md](sessions/session-06-telegram-parity.md);
report: [sessions/session-06-report.md](sessions/session-06-report.md).
Earlier: Session 4 [sessions/session-04-ux-fixes.md](sessions/session-04-ux-fixes.md);
Session 2 [sessions/session-02-stabilize-ux.md](sessions/session-02-stabilize-ux.md).
`v0.1.0` is still untagged — the founder's acceptance pass is the next
touch. Session 1: [sessions/session-01-report.md](sessions/session-01-report.md).
Concept: [CONCEPT.md](CONCEPT.md) · Decisions & module map: [ARCHITECTURE.md](ARCHITECTURE.md)
Session 1 implementation layer: [sessions/session-01-plan.md](sessions/session-01-plan.md)

## Open-source release (v0.1.0)

NotchGram is public under GPL-3.0-or-later at
[github.com/f1lcry/notchgram](https://github.com/f1lcry/notchgram), with a
fresh history (one root commit; the pre-release history is kept privately).

- Done: public README with demo-mode media, LICENSE, THIRD_PARTY_NOTICES (also
  shipped inside the app bundle), CONTRIBUTING, SECURITY, issue and PR
  templates; docs scrubbed of personal data.
- Done: Release hardening — DebugBridge, checkpoint notifier and demo mode are
  compiled out of Release and `make verify-release` proves it (D43).
- Done: Sparkle 2.9.6 auto-update over a GitHub-hosted appcast (D43); arm64-only
  notarized DMG (D44); Homebrew cask at `f1lcry/tap/notchgram`;
  `make release VERSION=x.y.z` publishes all of it.
- Done: UI language follows the system unless set explicitly (D35); reply
  quotes and clickable links in bubbles; app icon; demo mode for docs media (D45).

## Delivery model — autonomous build sessions

Development happens in a small number of long, autonomous Claude Code
(ultracode) sessions. Each session has a written brief in `docs/sessions/`
that acts as its contract: scope tiers, milestone order, verification gates,
the exact founder checkpoints, and definition of done. The executing agent:

- works in a session branch, commits per milestone (conventional commits),
  pushes as it goes;
- verifies every milestone through the four-layer protocol below;
- merges to `main` and tags only when the brief's acceptance checklist is
  green (that merge is pre-authorized by the brief itself);
- ends by writing `docs/sessions/session-NN-report.md` (what shipped,
  deviations from the brief, debt, learnings) and updating ROADMAP /
  ARCHITECTURE / the next session's brief accordingly.

Founder involvement per session — by design, exactly three touches:

1. **CP0** — launch the session.
2. **CP1** — one ~2-minute interactive Telegram login when pinged
   (non-blocking: everything else runs against the Telegram test DC until
   then; only the final real-account milestone hard-depends on it).
3. **CP2** — final look & accept.

## Verification protocol (all sessions)

| Layer | What | When |
| --- | --- | --- |
| L1 Unit | `make test`: auth/panel state machines, repos over a mocked TDLib transport | every milestone |
| L2 Integration | `make itest`: headless harness on the Telegram **test DC**. Three sections, each reported separately: *live auth probe* (cold start → 14-field `setTdlibParameters` → phone → `waitCode`) **passes**; *live round trip* (send/receive/media) is **skipped with cause** — Telegram's test-DC simplified login is broken server-side (see below); *update replay* over `UpdateFixtures` runs in `make test`. Zero founder involvement | every milestone touching TelegramCore |
| L3 UI smoke | build & launch the real app; DebugBridge forces states (expand, auth screens, open chat) and is the **primary** path; `screencapture -l <windowNumber>` shots reviewed by the agent, with an in-app `ImageRenderer` capture as the TCC-free fallback; one pointer-level hover per UI milestone via `CGWarpMouseCursorPosition` (needs no Accessibility grant, and suffices because hover is polled) | every UI milestone |
| L4 Real-account probe | after CP1: real chat list renders, message to Saved Messages round-trips, a real photo downloads and renders | release milestone |

Evidence (screenshots, logs, test output) goes to `.artifacts/` and is
referenced from the session report. `.artifacts/` is gitignored and stays on
the development machine — after CP1 it holds real chat content — so the
evidence file names cited in the reports are not published.

**The test DC's simplified login is broken on Telegram's side** (measured in
M2; the documented code is rejected with `PHONE_CODE_INVALID`, reproducing for
everyone in [tdlib/td#3083](https://github.com/tdlib/td/issues/3083) since
2021, including for `tg_cli` with the sample api_id). The fallback the brief
anticipated is therefore in force, in the narrow form that is actually
truthful:

- the **inbound** direction is mocked — `UpdateFixtures` synthesizes update
  sequences and the repos' `apply(Update)` paths are replayed offline, which is
  where the real ordering and send-correlation bugs live;
- the **outbound** direction is *not* mocked. A round trip asserting "the text
  I sent appears in history" against a fake that put it there proves nothing;
- consequently **live send/receive/media verification moves to L4**, on the
  founder's real account after CP1.

This makes CP1 load-bearing rather than convenient: it is now the only route to
live chat data. The ping therefore fires as soon as M4's UI can accept a phone
number, not after M4 is fully verified.

## Session 1 — MVP: single-account client → v0.1.0

Brief: [sessions/session-01-mvp.md](sessions/session-01-mvp.md)

One session ships a genuinely usable daily-driver client for one account.
Scope is tiered so the session degrades gracefully instead of stalling:

- **T1 — core (hard requirement):** notch shell + hover panel, full auth,
  live chat list (pinned/groups/channels/bots), conversation view with text
  send/receive and read states, inline media *viewing* (photos, stickers,
  GIFs, voice playback; video as thumbnail → external), chat search,
  settings (panel size, launch at login), and — pulled forward from Phase 3 —
  synthetic-notch mode plus a multi-display policy (D14/D15), because the
  founder frequently works on external, notch-less displays.
- **T2 — expected (target of the session):** sending photos/files
  (drag-drop / paste / attach), reply-to, edit/delete/copy context menu,
  typing indicators, chat folders as tabs, basic notifications.
- **T3 — stretch (budget-permitting):** voice recording, reactions,
  forwarding, animated (TGS) stickers, link previews, mute controls,
  archived chats.

Exit: acceptance checklist in the brief green with evidence → merge, tag
`v0.1.0`, `make install`.

**Outcome.** M0–M9 are done; M10 is blocked on CP1. Two T2 items were
deliberately left for Session 2 because they cannot be verified unsigned-in:
reply-to with the edit/delete context menu, and drag-and-drop onto the
*collapsed* notch (dropping onto the expanded panel works). Notarization was
pulled forward into this session at the founder's request and is verified.

## Session 2 — Stabilization & UX (founder-initiated) — shipped

Brief + report: [sessions/session-02-stabilize-ux.md](sessions/session-02-stabilize-ux.md)

Unplanned session forced by the first days of real use: the M6 conversation
path livelocked the main thread at 13 GB, the expanded panel blacked out the
menu bar, the shadow clipped, the first click from another app was eaten, and
the message UI read as an alpha. All fixed and verified against the founder's
real account (history stress flat at ~200 MB, pointer-probe hover/click/
collapse green); plus RU localization, tdesktop night theme over Liquid
Glass, grouped bubbles, reactions, round video notes, channel mute footer.
Installed to `/Applications`. The M10 checklist from Session 1 is the next
founder touch.

## Session 4 — Shell & data-layer fixes (founder-initiated) — shipped

Brief + report: [sessions/session-04-ux-fixes.md](sessions/session-04-ux-fixes.md).
Branch `session-04-ux-fixes`. Centred dropdown replaces the mushroom (D36),
click-to-type works everywhere (D37), folder sync/pins/badges fixed at the
`ChatOrderIndex` contract, Telegram-style search (chats + public + messages).
Installed to `/Applications`; the M10 pass remains the founder's next touch.

## Session 6 — Telegram Desktop parity (founder-initiated) — built

Brief: [sessions/session-06-telegram-parity.md](sessions/session-06-telegram-parity.md) ·
report: [sessions/session-06-report.md](sessions/session-06-report.md).
Branch `session-06-telegram-parity` (off `session-04-ux-fixes`). Eight
parity complaints from the founder's CP0 voice brief: clicks (folder tabs
hit only their glyphs — C1), open position + scroll memory (C2), the
fast-scroll crash and unbounded media memory (C3, D41/D42), album mosaics
(C4), the in-panel media viewer (C5), inline round-message playback +
Telegram transcription (C6), avatar bleed (C7), and the stuck-open panel
(C8, D40).

## Session 3 — Multi-account → v0.2.0

Brief: [sessions/session-03-multiaccount.md](sessions/session-03-multiaccount.md)

Parallel TDLib clients over the day-1 `AccountRegistry`; add-account flow
(reusing the auth UI); fast switching that beats official Telegram (avatar
strip + ⌘1…⌘9 + cycle hotkey); per-account and aggregate unread badges;
per-account notifications. The brief is re-baselined against the Session 1
and 2 reports before execution (first 30 minutes of the session).

## Phase 3 — backlog (unscheduled)

- Non-notch fallback: **corner trigger** only. The synthetic drawn notch moved
  into Session 1 scope (D14) — external displays are the founder's daily case.
- Min-macOS review for older hardware (currently 26, D4).
- Rich collapsed-state widgets (unread ticker, active-chat preview).
- CI on GitHub Actions macOS runners — only if it ever earns its 10× minute
  cost; the local verification protocol covers today's needs.
