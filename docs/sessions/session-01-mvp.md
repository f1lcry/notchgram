# Session 1 — MVP build brief (→ v0.1.0)

Contract for one long autonomous ultracode session. Read in this order
before writing code: this file → [session-01-plan.md](session-01-plan.md) →
[../ARCHITECTURE.md](../ARCHITECTURE.md) → [../CONCEPT.md](../CONCEPT.md) →
repo `CLAUDE.md`. Decisions D1–D23 are made; do not re-litigate them — apply
them, and if one breaks in practice, change it, update ARCHITECTURE.md, and
record why in the session report.

**`session-01-plan.md` is the implementation layer beneath this contract.**
It carries the facts this brief left open, already verified against primary
sources — the exact TDLibKit pin and its *static*-framework linkage, the full
14-field `setTdlibParameters`, the test-DC number/code rule, the keyboard-focus
recipe for a non-activating panel, the multi-display / synthetic-notch policy,
the `xcresulttool` invocation on Xcode 26.6, and the media decode facts. Do not
re-derive them.

## Mission

Ship NotchGram v0.1.0: a genuinely usable single-account Telegram client in
the notch panel — good enough to be the founder's daily driver for reading
and answering Telegram. Target scope: T1 fully + T2 fully (see ROADMAP
tiers); T3 as budget allows.

## Hard constraints

- Secrets only via `.env` → `scripts/gen-secrets.sh` → gitignored generated
  Swift. Never committed, never logged, never echoed into command output.
- Bundle id `com.f1lcry.notchgram`, automatic signing, the author's team —
  frozen from the first build (TCC identity).
- Swift 6 strict concurrency from day one; `@preconcurrency` only where a
  dependency forces it (list such spots in the report).
- Branch `session-01-mvp`; conventional commits per milestone; push after
  each milestone. Merge to `main` + tag `v0.1.0` only with the acceptance
  checklist green — that merge is pre-authorized by this brief.
- Every UI state reachable via DebugBridge, never only via physical hover —
  this is what keeps the session self-testing.
- All screenshots/logs/evidence into `.artifacts/` (gitignored). After CP1
  these contain the founder's real chats — never quote real chat content into
  the session report or a commit message.
- **Never `pkill`/SIGKILL the app** (D20). TDLib holds an encrypted SQLite
  open; a hard kill risks a corrupt database, and a corrupt database after CP1
  costs a founder re-login. Quit via DebugBridge → `osascript` → `-TERM`.
- Work happens in the `session-01-mvp` git worktree, not the main checkout.

## Founder checkpoints (the only ones)

- **CP0** — founder launches the session.
- **CP1** (non-blocking) — after M4 lands, ping the founder to log the real
  account in **through the panel UI itself** (phone → code → 2FA; ~2 min; also
  dogfoods the auth flow). Fallback if the UI blocks: `make login` CLI. Keep
  building against test-DC accounts while waiting; only M10 hard-depends on
  CP1. Before relaunching the app while CP1 is pending, query DebugBridge
  status — don't kill a login in progress.
  The ping is a user notification **plus** a grant-free fallback
  (`osascript -e 'display notification'` / a status file) fired in parallel,
  and `UNUserNotificationCenter` authorization is requested back in M0 — the
  authorization prompt would otherwise be an unbudgeted fourth founder touch
  that silently swallows this ping.
- **CP2** — final acceptance look after M10.

## Milestones

Each milestone: implement → verify (gates listed) → conventional commit →
push. Gates refer to ROADMAP verification layers L1–L4.

- **M0 Scaffold + de-risking spikes.** XcodeGen `project.yml` (app target
  `NotchGram` (LSUIElement) + `Unit`/`UITests` + `ITest` `tool` target),
  `Makefile` (`deps generate build test uitest itest login run quit install
  screenshot logs clean distclean`), gen-secrets pipeline, `.env` consumed,
  `scripts/preflight.sh` extended with the TCC probes and green, minimal panel
  + DebugBridge v0, `UNUserNotificationCenter` authorization requested.
  Mirror Dictate's `project.yml`/`Makefile` conventions — but note that
  `itest`, `login`, `screenshot`, the CLI target, the gen-secrets build phase
  and the whole `.artifacts/` pipeline have **no Dictate precedent** and are
  new work; budget M0 accordingly.
  **Four exit gates — all four, or stop and reassess** (details in the plan):
  **G1** `make deps` resolves the pinned TDLibKit tag (~343 MB, started first
  and in the background); **G2** the app builds, links + signs the static
  TDLibFramework *under Xcode 26.6* and prints TDLib's version from
  `getOption("version")`; **G3** the keyboard-focus spike passes inside the
  real signed bundle (synthetic click + keystrokes land in a `TextField`,
  `frontmostApplication` unchanged); **G4** `make test` green and
  `make screenshot` yields a non-empty PNG of the panel window. Also run
  `make distclean && make build` once to prove the fresh-clone path. Gate: L1.
- **M1 TelegramCore foundation.** TDLibKit pinned by exact version in
  `project.yml` (record version + bundled TDLib version in the report);
  singleton `TDLibClientManager`; `TDClient` actor + update stream;
  `AuthFlow` state machine; `AccountRegistry` with per-account db dirs +
  Keychain db keys; test-DC support (`useTestDc`) as an account attribute.
  Verify the exact current test-DC contract (reserved numbers `99966DXXXX`,
  fixed codes) against TDLib docs. Gate: L1.
- **M2 Test-DC integration green.** `make itest`: creates/logs into a
  test-DC account headlessly, send+receive round-trip (Saved Messages or a
  second test account), media file download. Retries built in; if the test
  DC is unusable, fall back per ROADMAP and note it. Gate: L1+L2.
- **M3 NotchShell.** Port the Dictate notch engine (see Reuse map): polled
  hover expand/collapse with animation and grace period, panel per D8 (default
  880×580, persisted, Settings-backed, **clamped per screen** — Dictate never
  implemented the clamp), fullscreen-Space behaviour per D22, DebugBridge v1
  (expand/collapse, set-size, goto-auth-state, open-chat, force-synthetic,
  screenshot, status, quit).
  **Expanded scope (founder works on external displays; three are attached):**
  synthetic-notch mode is MVP and is the *primary dev surface*, sized per D14;
  one panel per screen per D15 with the composer draft lifted into a shared
  store; `didChangeScreenParameters` → debounced `rebuild()`; and the
  `ScreenInfo` / `ScreenProvider` / pure-`NotchGeometryEngine` extraction so
  every topology (incl. clamshell and hot-unplug, which cannot be exercised
  unattended) is covered by unit fixtures. Also: carve the expanded panel's
  top-strip flanks out of the hit region — at 880 pt wide, a `.statusBar`-level
  panel otherwise swallows most menu-bar clicks. Gate: L1+L3.
- **M4 Auth UI.** Phone → code → 2FA → ready, error states, logout;
  verified end-to-end on a test-DC account through the real panel UI.
  → Fire **CP1** notification. Gate: L1–L3.
- **M5 Chat list (T1).** Live main list: pinned section first, avatars,
  titles, last-message preview, unread badges, mute state; private/group/
  channel/bot chats all render; live reorder on new messages;
  connection-state banner. Gate: L1–L3.
- **M6 Conversation (T1).** Open chat → history with backwards pagination,
  live incoming messages, text composer (Enter send / Shift+Enter newline),
  send states (pending → sent → read), failed-send retry, date separators,
  sane scroll anchoring. Gate: L1–L3.
- **M7 Media (T1 view + T2 send).** Inline photos (thumb → full), static
  stickers, GIFs, voice playback, video as thumbnail+duration opening the
  downloaded file externally; sending photos/files via drag-drop onto the
  panel, paste-image, attach button; reply-to; context menu (copy, edit own,
  delete for me/for all). Gate: L1–L3.
- **M8 Search, profile, settings (T1).** Global chat search → open result;
  self profile view; Settings: panel size (presets + custom, D8), collapsed
  unread-badge toggle (D10, default off), launch at login, logout. Gate: L1–L3.
- **M9 T2 remainder.** Typing indicators, chat folders as tabs, basic
  notifications (per-chat, respecting mute). If the session is running long,
  move items to the stretch loop rather than letting the release slip.
  Gate: L1–L3.
- **M10 Real-account verification + release.** Requires CP1. L4 probe on
  the real account; perf sanity (cold start < 2 s to expanded panel, smooth
  chat-list scroll, idle RAM under ~400 MB — investigate anomalies, don't
  gate on exact numbers); fix what the probe surfaces; acceptance checklist
  below with evidence; write `session-01-report.md`; update ROADMAP /
  ARCHITECTURE / session-02 brief; merge to `main`, tag `v0.1.0`,
  `make install`. Gate: L1–L4. → **CP2**.
- **M11+ Stretch loop.** While budget remains, pull the next item — first
  anything deferred from M9, then T3 order: voice recording, reactions
  (view → set), forwarding, animated TGS stickers, link previews, mute
  controls, archived chats. One item at a time, each fully verified,
  committed, merged.

## Acceptance checklist (v0.1.0)

- [ ] Fresh login flow works on the real account (phone/code/2FA) in-panel
- [ ] Hover notch → panel expands ≤ 300 ms; leaves → collapses after grace
- [ ] Chat list shows the founder's real chats: pinned first, correct unread
      counts, live reorder on incoming message
- [ ] A busy group chat scrolls back ≥ 200 messages smoothly
- [ ] Text round-trip: send from NotchGram → visible on phone; reply from
      phone → appears live in the open chat
- [ ] Received photo renders inline; photo sent from panel (drag-drop AND
      paste) arrives on phone
- [ ] Sticker and GIF render; voice message plays
- [ ] Reply-to and edit-own-message work on the real account
- [ ] Search finds a chat by title and opens it
- [ ] Panel size changes in Settings and persists across app restarts
- [ ] Panel can be **summoned** over a fullscreen app's Space (D22)
- [ ] Official Telegram Desktop not running the whole time — full independence
- [ ] Launch-at-login works after reboot-equivalent (logout/login or manual check)
- [ ] No secrets in git history (`git log -p | grep` for api hash — clean)
- [ ] `make test` and `make itest` green; evidence bundle in `.artifacts/`
      referenced from the session report

## Reuse map (read before M3)

Dictate (the author's earlier notch app) — port, namespaced, into
`Sources/NotchShell/` (no cross-repo dependency, D7):

- `Sources/Notch/NotchGeometry.swift` — notch rect / safe-area detection
- `Sources/Notch/NotchController.swift` — window + hover lifecycle
- `Sources/Notch/NotchShape.swift`, `NotchView.swift` — panel chrome and
  drawn-notch rendering (basis for synthetic-notch mode)
- `Sources/Notch/FullScreenProbe.swift` — fullscreen-Space handling
- `project.yml`, `Makefile` — xcodegen/signing/build conventions

## Fallback playbook

- **TDLibKit unusable** (build breaks, critical API missing) →
  `brew install tdlib` + minimal `libtdjson` JSON bridge (dlopen + Codable
  envelopes) behind the same `TDClient` surface.
- **Test DC down/flaky** → mocked-transport integration tests now, live
  verification deferred to M10; note in report.
- **XCUITest flaky under automation** → rely on DebugBridge + CGEvent +
  `screencapture` (already the primary path); keep XCUITest minimal.
- **Dev display without a physical notch** → this is the *normal* case here,
  not a fallback: three displays are attached (notched built-in + two
  notch-less externals) and the pointer usually sits on an external one.
  Synthetic-notch mode is the primary test surface from M3; drive states via
  DebugBridge force-expand rather than hover, and cover both geometries with
  unit fixtures. Virtual-display tooling is a dead end (`displayplacer` cannot
  create displays, BetterDisplay needs a running GUI app, `CGVirtualDisplay` is
  private API) — do not open that branch.
- **Anything ambiguous in Telegram semantics** (ordering, read states) →
  mirror observable Telegram Desktop behavior; when unsure, check TDLib docs
  via Context7/web, don't guess silently.

## Definition of done

Acceptance checklist green with evidence; `v0.1.0` tagged and installed to
/Applications; docs and session-02 brief updated; `session-01-report.md`
written; founder pinged for CP2.
