# NotchGram — Architecture

Companion to [CONCEPT.md](CONCEPT.md). Records the resolved technical
decisions and the target structure. Decisions D14–D23 and the corrections
below come from [sessions/session-01-plan.md](sessions/session-01-plan.md),
which carries the evidence for each. Written before the first line of code;
the executing session updates it whenever reality disagrees (and notes the
change in its session report).

## System overview

NotchGram is a standalone macOS Telegram client. TDLib talks MTProto
directly to Telegram's servers — there is no backend of ours anywhere. The
UI lives in a borderless always-on-top panel anchored to the MacBook notch;
hovering the notch expands it into a ~Telegram-Desktop-sized mini client.

```
┌────────────────────────────────────────────────────────────┐
│ App (LSUIElement, AppKit lifecycle, DI, login item)        │
│                                                            │
│  NotchShell                Features (SwiftUI)              │
│  ├─ NotchWindow            ├─ AuthView                     │
│  ├─ NotchGeometry          ├─ ChatListView                 │
│  ├─ HoverTracker           ├─ ChatView (history+composer)  │
│  └─ PanelStateMachine      ├─ SearchView                   │
│                            ├─ SettingsView / ProfileView   │
│  DebugBridge (DEBUG)       └─ Media views (photo/sticker/  │
│  └─ control channel            gif/voice/video-thumb)      │
│                                                            │
│  TelegramCore                                              │
│  ├─ TDClient (actor, 1/account) ── TDLibKit ── TDLib ──────┼── Telegram DCs
│  ├─ AuthFlow (state machine)                               │
│  ├─ AccountRegistry (day-1 multi-account indirection)      │
│  ├─ ChatRepo / MessageRepo (@MainActor stores)             │
│  └─ FileStore (download/upload tracking)                   │
│                                                            │
│  Persistence: TDLib SQLite (encrypted, per account) ·      │
│  Keychain (db keys) · UserDefaults (UI prefs)              │
└────────────────────────────────────────────────────────────┘
```

## Modules

### App
Background app (`LSUIElement`, no Dock icon), AppKit lifecycle
(`NSApplicationDelegate`), dependency wiring, launch-at-login toggle.

### NotchShell — window engine
- `NotchPanel`: borderless non-activating `NSPanel` (`canBecomeKey → true`,
  `becomesKeyOnlyIfNeeded = true` — without the latter the first click from
  another app is spent on key transfer, D33), status-bar window level,
  `collectionBehavior` joining all Spaces including fullscreen apps. **One
  panel per attached screen** (D15) — shared app state, per-screen panel
  state, exactly one expanded at a time.
- **Window = slab, no drawn shadow** (Session 5, amends D33/D36 — Dictate's
  chrome verbatim): the NSPanel frame *is* the panel rect; the slab is a
  plain black `NotchSlabShape` (Dictate's top-filleted rectangle) with no
  SwiftUI shadows, no stroke, no glass backdrop. Session 2's 72 pt "shadow
  margin" + two-layer shadow read to the founder as the window being cut
  off; a flat black slab against the screen edge needs neither. The slab is
  centre-aligned on the anchor axis and grows straight down; open, it may
  cover the middle of the menu bar — the panel is transient. (Session 2's
  mushroom and its carve-outs are gone, as is the Session-2 chrome bug that
  left-aligned the collapsed tab outside its own hover trigger.) Collapsed,
  the same animatable shape degenerates to the plain bottom-rounded tab.
  Content lays out at full panel size at all times, inset by the shape's
  side radius (the slab body is narrower than its rect below the top
  flare), and is clipped/faded by the shape — never re-laid-out mid-fold.
  Open, the slab fills with the theme's `panelShell` navy (collapsed stays
  pure black to read as the notch). Dwell is Dictate's single 150 ms with
  Dictate's trigger slop. Coverage (fullscreen probe, own windows excluded)
  affects exactly one thing — the collapsed tab's alpha: the window is
  never ordered out and the pointer is always tracked, so hover and
  force-expand summon the panel over a fullscreen Space (D22); anything
  stronger produced a "phantom" — a live trigger with an invisible panel.
- **Text input needs the panel's help** (Session 4, D37): on left mouse-down
  `NotchPanel.sendEvent` takes key status itself (`becomesKeyOnlyIfNeeded`
  never fires for SwiftUI text fields) and focuses the editable AppKit text
  view under the click (SwiftUI refuses focus-by-click while the app is
  inactive). Without both, no field in the panel — search, composer, auth —
  ever accepts a keystroke.
- `NotchGeometryEngine` / `ScreenInfo`: a *pure* function from `[ScreenInfo]`
  and settings to `[NotchGeometry]`, behind a `ScreenProvider` protocol so
  every display topology is unit-testable without hardware. Physical notch is
  detected by `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` being non-nil —
  never by `safeAreaInsets.top > 0` (which tracks menu-bar visibility) and
  never via `NSScreen.main` (which follows the key window). Synthetic-notch
  rect for displays without a cut-out (D14).
- `HoverTracker`: a **poll loop** over `NSEvent.mouseLocation` (D16) — not a
  tracking area and not SwiftUI `.onHover`; debounced expand, grace-period
  collapse, pinned open while the composer is focused, a context menu is up,
  a drag is in flight, or DebugBridge forces it.
- `PanelStateMachine`: collapsed ↔ expanding ↔ expanded ↔ collapsing.
- Pattern source: Dictate, the author's earlier notch app (its notch module
  — `NotchGeometry`, `NotchController`, `NotchShape`, `NotchView`,
  `FullScreenProbe`). Copied and adapted under our namespace, deliberately
  not a shared package (D7).

### TelegramCore — TDLib layer
- `TDLibClientManager` is a **process-wide singleton** (TDLib's `td_receive`
  must run on a single thread). Each account is one client id under it.
- `TDClient`: actor per account wrapping its client id; typed request API +
  `AsyncStream` of updates.
- `AuthFlow`: state machine mirroring TDLib authorization states. TDLib 1.8.66
  defines **13** of them — beyond the happy path (`waitTdlibParameters →
  waitPhoneNumber → waitCode → waitPassword → ready`) it can emit
  `waitRegistration` (always, for a fresh test-DC number), `waitEmailAddress`,
  `waitEmailCode`, `waitOtherDeviceConfirmation`, `waitPremiumPurchase`,
  `loggingOut`, `closing`, `closed`. All 13 are modelled, with an explicit
  `unsupported(String)` UI leaf so a surprise state degrades to a readable
  screen instead of a hang during CP1.
- `AccountRegistry`: configured accounts; each = isolated TDLib database
  directory + its own Keychain-stored db key. MVP exposes one account in the
  UI, but the indirection exists from day one (D9) — test-DC accounts also
  live here as ordinary accounts, which is what makes automated testing and
  the real account coexist cleanly.
- `ChatRepo` / `MessageRepo`: `@MainActor` observable stores fed by the
  update stream — chat-list order (incl. pinned), unread counters, per-chat
  message windows, send pipeline with optimistic UI and retry. Bulk
  mutations publish **once per batch**, never per message; live growth of the
  open conversation is capped at 1500 rows (D34). `ChatRepo` also resolves
  posting rights (chat permissions + own `updateSupergroup` member status →
  `ChatSummary.canSendMessages`) and owns the mute toggle.
- `FileStore`: TDLib file download/upload progress → local paths for media.
  Observation is **per file** through `FileBox` slots (one `@Observable`
  dictionary meant every progress tick of any download invalidated every
  view, D34); progress writes throttle to 256 KB steps, state transitions
  always publish.

### Features — SwiftUI content inside the panel
Auth (phone/code/2FA), chat list (folders as tabs when they land), chat view
(history + composer), search, settings, profile, media rendering (photos,
static stickers, GIFs, voice player via AVFoundation, video as
thumbnail+duration opening externally in MVP).

### DebugBridge — the autonomy hook
HTTP over a Unix domain socket (D31, amending D18's transport), compiled into every configuration but
**inert unless enabled** (`defaults` key `DebugBridgeEnabled` or the
`NOTCHGRAM_DEBUG_BRIDGE=1` environment variable) — D18. It ships in Release
because launch-at-login and the real-account probe may only be exercised
against the `/Applications` copy, which is the Release build. HTTP is the
transport because the harness must read status back *synchronously from one
shell command*, which a URL scheme (fire-and-forget) and
`DistributedNotificationCenter` (no reply primitive) cannot do; the
`notchgram://` scheme remains as a secondary, human path. Capabilities:
force expand/collapse, set panel size, jump to any auth state, open chat by
id, switch active account, toggle synthetic notch, capture the panel in-app
(`ImageRenderer` — needs no Screen Recording grant), quit gracefully, and
report app status machine-readably (auth state, connection state, active
account, panel state + frame, `NSWindow.windowNumber` for `screencapture -l`,
and the resolved `[ScreenInfo]` / `[NotchGeometry]` so geometry assertions are
diffable rather than a screenshot squint). A command returns the
**post-transition** state, so the harness never races the unfold animation.
**Rule: every UI state reachable by a human must be reachable through
DebugBridge without a physical mouse hover.** This is what lets an agent
build and verify the app without a human at the pointer.

### Persistence
- TDLib-managed encrypted SQLite per account (chats, messages, media cache).
- DB encryption key: 256-bit random, generated on first run per account,
  stored in Keychain (D6).
- `UserDefaults` for UI prefs only (panel size, toggles). Nothing syncs
  anywhere by us.

## Threading model
Swift 6 strict concurrency. `TDClient` is an actor; the TDLib update stream
is consumed off-main and re-published on `@MainActor` to the repos/SwiftUI.
No blocking main-thread calls; file transfers are observed via updates, not
polled.

## Secrets
`TELEGRAM_API_ID` / `TELEGRAM_API_HASH` live in `.env` (gitignored);
`.env.example` is the committed contract. `scripts/gen-secrets.sh` (build
phase) generates `Secrets.generated.swift` (gitignored) — the only
consumption path. Embedding api_id/hash in the built binary is normal and
unavoidable (official clients ship theirs too); the rule is: never in git,
never in logs.

## Decisions

| # | Topic | Decision | Rationale / revisit trigger |
| --- | --- | --- | --- |
| D1 | TDLib binding | TDLibKit (Swiftgram) via SPM — typed generated API over prebuilt TDLibFramework xcframework (~300 MB dep download, no source build) | Fastest autonomous path. Revisit → thin `libtdjson` bridge (dlopen + Codable) if TDLibKit lags a needed TDLib feature; keep `TDClient`'s surface identical so a swap stays contained. |
| D2 | UI stack | Swift 6 strict concurrency; AppKit window shell + SwiftUI content | Same as Dictate; proven for notch overlays. |
| D3 | Project generation | XcodeGen — `project.yml` committed, `.xcodeproj` gitignored; deps pinned by exact version in `project.yml` | Deterministic and agent-editable; same convention as Dictate. |
| D4 | Min macOS | 26 (match Dictate) | Only the founder's machine matters until Phase 3; fallback hardware may lower this later. |
| D5 | Secrets | `.env` → build-time generated Swift; `.env.example` committed | Founder requirement: tracked contract, no hardcode. |
| D6 | TDLib db encryption | Random 256-bit key per account, stored in Keychain | Spec open question resolved. |
| D7 | Dictate relationship | Fully separate app; bundle id `com.f1lcry.notchgram`; notch engine copied from Dictate, not extracted into a shared package | Extract a shared package only when both apps need the same change twice. |
| D8 | Panel size | Default 880×580 pt (founder's Telegram Desktop measured 890×584 on 2026-08-22); adjustable in Settings (presets + custom) within 640×420 … screen-safe max; persisted | Founder requirement: "about the size of my Telegram window", configurable. |
| D9 | Multi-account readiness | `AccountRegistry` + per-account db dirs/keys + client-per-account from day 1; MVP UI shows one account | Makes Session 2 additive rather than a refactor; also hosts test-DC accounts. |
| D10 | Collapsed state | MVP default: fully passive (plain notch extension); minimal unread-count badge available behind a Settings toggle | Keeps MVP scope; rich collapsed widgets are Phase-3 backlog. |
| D11 | Distribution | Debug builds are signed **Apple Development** (automatic); the Release build is re-signed **Developer ID Application** by `make sign-release` and is the *only* thing `make install` puts in /Applications. **Amended at CP0: notarization is in Session 1 scope, not Phase 3** (see D24) | Solo user for now. One identity per installed bundle, permanently: alternating leaf certificates changes the code requirement, which invalidates `SMAppService` login-item registration and can re-trigger TCC prompts. |
| D12 | Verification | Four-layer protocol (unit / test-DC integration / UI smoke via DebugBridge / real-account probe) — see [ROADMAP.md](ROADMAP.md) | Autonomy requirement. |
| D13 | Automated Telegram testing | Telegram **test DC** (`useTestDc`), reserved numbers `99966DXXXX` (D = dc id) with fixed verification codes — confirm the exact current contract in TDLib docs during Session 1 M1 | Lets an agent exercise real login + messaging end-to-end with zero founder involvement; test accounts are isolated from production. |
| D14 | Synthetic notch | Ships in the MVP, not Phase 3. Drawn tab ≈ **half** a real notch's width (`clamp(round(realNotchWidth * 0.5), 88, screen.width * 0.4)`, ≈92 pt here) and ≈half the menu-bar height (10–16 pt), centred on `midX`; hover trigger inflated ±14 pt laterally, +10 below and +4 above `frame.maxY` | The founder frequently works on external, notch-less displays (three displays attached today). CONCEPT.md asks for "roughly half the width of a real one" — Dictate draws it full width, so a naive port silently violates the requirement. |
| D15 | Panels per screen | One fixed-frame panel per attached screen with shared app state; exactly one expanded at a time (the existing `latched` handoff). Panels never migrate between screens | Discoverability wherever the pointer is, and this is what the ported engine already does. Composer draft / active chat / scroll anchor must live in shared stores, or a display hot-plug rebuild eats a half-typed message. |
| D16 | Hover detection | Polled `NSEvent.mouseLocation` (80 ms idle / 40 ms open), never `NSTrackingArea` and never SwiftUI `.onHover` | Tracking areas lose the pointer when it is pressed against the screen top → no `mouseExited` → stuck panel; `.onHover` is scoped to the active app and is dead for a background app. Hard-won in Dictate. |
| D17 | Keyboard focus | `.nonactivatingPanel` + `canBecomeKey → true`; a click takes key, Esc = `makeFirstResponder(nil)`. **Never** call `NSApp.activate()`; treat `NSApp.isActive` as meaningless and use `panel.isKeyWindow` | Verified live on macOS 26.6: keystrokes reach a SwiftUI `TextField` in the panel while `frontmostApplication` never changes. Revisit trigger → if the real signed bundle ever fails this, drop `.nonactivatingPanel` and accept that expanding activates the app. |
| D18 | DebugBridge transport | Loopback HTTP on `127.0.0.1`, present in all configurations, inert unless enabled by a `defaults` key / env var | Only a socket gives request→response in one shell command. Must exist in Release because launch-at-login and the real-account probe can only be exercised against the `/Applications` (Release) copy. |
| D19 | ITest target | XcodeGen `type: tool` linking TDLibKit directly, recompiling `Sources/TelegramCore` | The TDLibFramework xcframework is a **static** framework (`MACH_O_TYPE: staticlib`), so a CLI links it with no embed phase and no `@rpath` work. Upgrade to a `framework.static` target once the TelegramCore API stabilises. |
| D20 | Process shutdown | Never `pkill`/SIGKILL NotchGram. Quit order: DebugBridge `quit` → `osascript -e 'quit app id …'` → `pkill -TERM` after a 10 s timeout | TDLib holds an encrypted SQLite open; a hard kill risks DB corruption, and a corrupt DB after CP1 costs a founder re-login. `osascript` can also raise a one-time Automation TCC dialog, which is why DebugBridge is first. |
| D21 | Notifications (MVP) | Pragmatic path: fire `UNUserNotificationCenter` from `updateNewMessage` where `!is_outgoing`, with mute resolved through `chatNotificationSettings.use_default_*` against `updateScopeNotificationSettings`; de-duplicated by `(chat_id, message_id)` across launches | The real `updateNotificationGroup`/`updateActiveNotifications` path gives cross-restart dedup, remote dismissal, mention grouping and `show_preview` — deferred to Session 2. Authorization is requested in M0 so CP1's ping cannot silently fail. |
| D22 | Panel over fullscreen | When a fullscreen window covers a display, the collapsed synthetic tab hides via `alphaValue = 0` + `ignoresMouseEvents = true` — **not** `orderOut` — and a non-hover expand (hotkey / DebugBridge) still works | Dictate orders synthetic tabs out entirely, which contradicts the acceptance requirement that the panel be reachable over a fullscreen Space (and only passes on the built-in because physical hosts are exempt). Checklist wording becomes "can be **summoned** over a fullscreen app's Space". |
| D23 | Swift 6 + TDLibKit | `@preconcurrency import TDLibKit` scoped to `Sources/TelegramCore`, plus one `TDLibKit+Sendable.swift` adding `@retroactive @unchecked Sendable` to the value types actually crossed (`Update, Chat, Message, File, ChatPosition, ChatFolderInfo, ChatNotificationSettings, ConnectionState, AuthorizationState`). `TDLibClient` (a class) never crosses an actor boundary | TDLibKit declares `swift-tools-version:5.3` and has **zero** `Sendable` conformances, so the package itself builds clean and all friction is at our call sites. Do not set `SWIFT_TREAT_WARNINGS_AS_ERRORS` project-wide — `TDLibClientManager` contains a literal `#warning`. |
| D24 | Notarization | Ships in Session 1 (founder has Apple Developer + a working `notarytool` keychain profile). `make notarize-app` zips the Developer ID Release build with `ditto -c -k --keepParent`, submits with `--keychain-profile $(NOTARY_PROFILE)` (default `dictate-notary`, overridable), staples the ticket into the **`.app`**, and asserts with `spctl -a -t exec`. `make dmg` is then built *from the stapled app*, and `make notarize` staples the DMG too. `make install` stays local-only and fast | Verified end-to-end at M0 on 2026-08-23 (submission `27feb2af…`, Accepted, `source=Notarized Developer ID`). Notarization uploads a binary containing the Telegram api_id/hash to Apple; that is expected and unavoidable — every Telegram client ships its own — and is not a leak under the "never in git, never in logs" rule. |
| D25 | Nested-code signing | `make sign-release` signs **inside-out**: every `Contents/Frameworks/*.framework` first, then the app | Despite `embed: false` and the xcframework being static (its `td_*` symbols land in our own binary; `otool -L` shows no dependency), Xcode still drops a ~51 KB *vestigial dynamic* `TDLibFramework.framework` stub — 0 exported `td_` symbols — into the bundle. It keeps the build-time Apple Development signature, and notarization requires Developer ID on every binary. |
| D26 | Every TDLib request is bounded | All requests go through `withDeadline(_:operation:)`; `TelegramSession` defaults to 45 s per user action, the ITest harness to 20–25 s per step | A TDLib request whose data centre is unreachable **never answers and never errors** — measured: a `99966**3**xxxx` number produced `PHONE_MIGRATE_3` and then an endless connect/retry loop (`Timeout expired … to DcId{3}`, `No route to host`). TDLibKit bridges every request through `withCheckedThrowingContinuation`, and task cancellation cannot resume a continuation, so `await` hangs forever. Unbounded, the panel would spin with no error and the harness would never fail over. |
| D27 | Quit sequence | `applicationShouldTerminate` returns **`.terminateCancel`** and a main-actor task re-issues `NSApp.terminate` after the async close; the second pass short-circuits to `.terminateNow`. A 10 s watchdog terminates anyway | `.terminateLater` parks AppKit in a nested wait loop that does **not** service Swift Concurrency's main-actor executor: measured, the shutdown task and the watchdog task both never ran a single line and the process was still alive 25 s later. A hung quit pushes the operator toward `kill -9`, which is the database corruption D20 exists to prevent. |
| D28 | Closing a TDLib client | Use the **completion** form `client.close(completion:)`, never `try await client.close()` | The manager routes a response by looking the client up in `clients` *after* removing it on `authorizationStateClosed`. When TDLib emits the closed state before the `Ok` for `close`, the completion is dropped and the async form's continuation is never resumed — a permanent hang on the quit path. The completion form allocates no continuation. The closed state itself is what `TDClient.shutdown` waits on, with a 5 s deadline. |
| D29 | Test-DC strategy (amends D13) | Automated live coverage stops at `authorizationStateWaitCode`. `make itest` reports three sections — live auth probe (passes), live round trip (**skipped, with cause and reference**), update replay (offline). `--live-roundtrip` re-attempts the full thing on demand. Live send/receive/media verification moves to **L4** on the real account | Telegram's test-DC simplified login is broken server-side: the documented code — the DC digit repeated, length taken from `authenticationCodeTypeSms.length`, which is the maintainer's own answer in tdlib/td#1524 — is rejected with `PHONE_CODE_INVALID`. Reproduced against DC 1 and DC 2 with 5-, 6- and 4-digit variants and confirmed in TDLib's request log; the same failure is reported for `tg_cli` with the sample api_id in tdlib/td#3083, open since 2021. A gate that can never go green is a gate everyone learns to ignore, so it is marked skipped rather than failed. |
| D30 | Mock only the inbound direction | `UpdateFixtures` synthesizes `Update` values; the repos' `apply(Update)` paths are replayed offline. No fake transport, no fake request layer | The repos already *are* `apply(Update)` functions, so a replay exercises the real code path. Faking the outbound side would mean asserting that a fake echoed back what it was handed — the send/receive assertion only means something against a real server, which is L4. The fixtures do double duty: they are also how the chat-list and conversation UI can be built and screenshotted before an account exists. |
| D31 | DebugBridge transport (amends D18) | HTTP over a **Unix domain socket** at `~/Library/Application Support/NotchGram/debug.sock`, served by a blocking `accept` on a dedicated thread with per-connection tasks and `SIGPIPE` ignored | The reasoning for HTTP is unchanged; loopback TCP is not. `NWListener(on: .any)` binds `*:port` on IPv6 even with `requiredInterfaceType = .loopback`, and macOS gates local-network access per application — the `/Applications` Release build completed the TCP handshake and then never received the request, with nobody there to approve it. A Unix socket is not networking. A `DispatchSource` read source on the listener also stopped delivering connections after a while, silently; a blocking accept has no arming semantics to get wrong. |
| D32 | Keychain access | Async and off the main actor; items created with an ACL that trusts **any** application | `SecItemCopyMatching` is synchronous IPC to `securityd` and does not return while a confirmation dialog is up — on the main actor that froze the entire app, panel included. The dialog exists because an item added without an explicit `kSecAttrAccess` binds to one code signature, and D11 mandates two. The trade is small: the secret is a local database key sitting beside the database it encrypts, under the same user's permissions. |
| D33 | Window vs slab (amends the D16/D17 recipe) | The NSPanel is the slab plus a 72 pt transparent margin (left/right/bottom); the expanded slab is stem-wide above the menu-bar line (`NotchSlabShape`); `becomesKeyOnlyIfNeeded = true` and `acceptsFirstMouse → true` | Session 1 sized the window exactly to the slab: the shadow and the spring's overshoot clipped at the edge (the founder's "cut-out shadow" / "it's cut off"), and the full-width top strip blacked out the menu bar. Without `becomesKeyOnlyIfNeeded` the first click from another app only transferred key status. All three were the founder's first live complaints. |
| D34 | UI publish discipline | Repos publish observable state once per batch; per-file `FileBox` observation; all image decodes go through a downsampling `ImageCache`; conversation rows carry stable identity (never array offsets); no `textSelection` in the message list (context-menu Copy instead) | The Session-1 freeze was a compounding of exactly these: per-message publishes × offset-keyed rows × full-res uncached decodes × platform-text-view churn drove the main thread into a livelock at 13 GB. Measured flat at ~200 MB after. |
| D35 | App language (amended by the open-source release) | An explicit `AppLanguage` preference (`ru` or `en`) wins; otherwise the system's first preferred language decides — `ru` gives Russian, anything else English. Previews, UI strings and date locales all resolve through it once per launch (`PreviewLanguage.system`) | Originally the default was `ru` as a fallback, because the author's macOS UI is English but the chats are Russian — following the OS locale would have kept the named Session-1 defect ("Photo" beside Cyrillic). A public build cannot assume Russian readers, so the system language now decides and the Russian-chat case is one explicit setting away. Inline `L10n.s(en, ru)` pairs instead of `.strings` files: two audiences only, and the pair stays readable at the call site. |
| D36 | Slab shape (amends D33) | The expanded slab is a plain top-filleted rectangle (Dictate's shape), **centre-aligned on the anchor axis**, growing straight down; the Session-2 mushroom and its menu-bar carve-outs are removed | The founder's verdict on the mushroom: the panel is transient, covering the menu bar while open is fine, and the stem-and-cap read as broken. Its chrome also aligned the slab to the window's leading edge, parking the collapsed tab ~390 pt off-centre and *outside its own hover trigger* — the "app stopped opening" bug. Centre alignment makes the collapsed tab, the trigger and the expansion share one axis by construction, and `testPanelIsCentredOnTheAnchorAxis` guards the contract. |
| D37 | Text input in the panel (amends D33) | On left mouse-down, `NotchPanel.sendEvent` takes key status and makes the editable AppKit text view under the click first responder itself | Two verified gaps: `becomesKeyOnlyIfNeeded` never fires for SwiftUI text fields (the hosting view does not report `needsPanelToBecomeKey`), and SwiftUI refuses focus-by-click while `NSApp` is inactive — probe showed window key with the first responder unmoved, while a direct `makeFirstResponder` worked. Neither `hitTest` (SwiftUI's gesture layer answers it) nor ancestor containment (SwiftUI containers are zero-sized with children outside bounds) finds the field, so the panel collects editable fields and containment-tests only them. Without this, no field — search, composer, auth — ever accepted a keystroke: the founder's "search doesn't work". |
| D38 | No `ScrollPosition` binding in the panel | The message list scrolls via `ScrollViewReader` + a bottom sentinel row; open-at-bottom and pagination stability come from `defaultScrollAnchor(.bottom)` for `.initialOffset` and `.sizeChanges` | On macOS 26 a `.scrollPosition(_:)` binding on a scroll view caught inside the panel's fold animation wedges SwiftUI's render loop **process-wide**: bodies keep evaluating (verified by breakpoint), but nothing paints ever again — every panel, every display, surviving a full `rebuild()`. The hover state machine keeps running, so the window sits at `ignoresMouseEvents = false` over frozen collapsed pixels: the founder's second "phantom window" (hover opens nothing, clicks near the notch are eaten). Reproduced headlessly with `expand → openChat → collapse → expand`; bisected to the binding alone — freeze gone with it removed, back with it restored. |
| D39 | Step-back input (amends D33/D37) | Esc steps back one level per press — release keyboard focus, then leave settings/profile, then close the open chat — routed in `NotchPanel.sendEvent` by key code; a horizontal two-finger swipe over the conversation pane closes the chat (`SwipeBackMonitor`, phased `scrollWheel` deltas). `becomesKeyOnlyIfNeeded` is **off** | Esc only reaches a key window, and with `becomesKeyOnlyIfNeeded` on, AppKit resigned key on every click outside a text field — the window server's key focus snapped back to the previously active app, so Esc (and typing) silently went there; AppKit-local `makeKey` re-takes after the fact do not move server-side focus. The feared first-click swallowing belongs to window *activation*, which a `.nonactivatingPanel` never does — verified by probe: a first click from another app opens the chat row under it. Esc is intercepted in `sendEvent` because with no field editor focused nothing on the responder path synthesises `cancelOperation`, and the hosting view swallows bare `keyDown`. Swipe uses scroll phases, not `NSEvent` swipe events, which only exist while the "swipe between pages" system gesture is enabled; wheel mice send no phases and are ignored. |
| D40 | Panel holds (amends D33's pinning) | One `Set<PinReason>` in `PanelSharedState` (`composerFocus`, `searchFocus`, `authFocus`, `filePicker`, `pendingOutgoing`, `mediaViewer`); each reason has exactly one owning surface, which clears it on the falling edge **and** in `onDisappear`. A hold only *keeps* an expanded panel open — never summons one. Focus holds are activity-scoped: pointer outside + no keystroke/click/scroll for 20 s releases them; a click outside every editable field ends the editing session (send re-focuses the composer); bridge `collapse` clears every hold | Session 4's single `pinnedHost` had five uncoordinated writers, none firing on view teardown — ordinary navigation destroyed the view before its releasing edge and latched the panel open forever (the founder's "the window got stuck"). Focus especially never releases on its own: one click into search meant the panel could not auto-close again for the rest of the session. |
| D41 | **Never SwiftUI `VideoPlayer`** | All video/GIF playback goes through `PlayerLayerView` (a bare `AVPlayerLayer` host); inline players are capped at 4 concurrent by `InlinePlayerBudget` | On macOS 26.6 `_AVKit_SwiftUI` aborts the whole process while instantiating its view metadata ("failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'") the moment a `VideoPlayer` materialises in a `LazyVStack` — reproduced deterministically by the fast-scroll stress; this was the founder's fast-scroll crash. The layer host also draws no controls chrome, which the bubbles want anyway. |
| D42 | Sliding history window (amends D34/D38) | `MessageRepo` trims BOTH directions at `maxLiveItems`: live/newer paths drop the oldest rows, scroll-back drops the newest and sets `hasMoreNewer` (the gap re-loads via `loadNewer`; the FAB re-anchors with `reloadLatest`; live appends are ignored while detached; sending re-anchors first). A chat opens at the saved position → first unread (with divider) → bottom; `ConversationView` is keyed per chat id so no scroll state leaks between chats. Read receipts follow rows actually seen (`noteVisible` → debounced `viewMessages`), never a blanket mark-all | Scroll-back had **no** trim at all (the RAM growth half of the fast-scroll crash), the reused conversation view leaked chat A's offset into chat B ("opens somewhere mid-chat"), and the Session-4 blanket read pass would have made an unread divider lie the moment it appeared. |
| D43 | Release hardening + auto-update (amends D18/D31) | DebugBridge (server, router, protocol), `CheckpointNotifier`, `DebugAuthStates`, `DebugFixtureScenarios` and demo mode compile under `#if DEBUG` only — absent from Release, not merely disabled. `make verify-release` fails the build if any marker string or symbol (bridge, checkpoint, demo) is in the Release executable, or if `SUFeedURL`, `SUPublicEDKey` or the bundled `THIRD_PARTY_NOTICES.md` are missing. Release embeds Sparkle 2.9.6 (`AppUpdater`, Release only); the feed is `https://github.com/f1lcry/notchgram/releases/download/feed/appcast.xml` (a fixed `feed` prerelease), and updates are signed with a dedicated EdDSA key held in the login keychain under account `notchgram` | The Release build is distributed to strangers: an unauthenticated local control socket is an attack surface even when switched off, so it must not exist. A string/symbol gate turns "compiled out" from a promise into a check. A NotchGram-only Sparkle key (not Dictate's) keeps one app's key compromise from signing the other's updates. `make release VERSION=x.y.z` signs the DMG and verifies the signature against the public key the built app ships with before anything is published. |
| D44 | Release is arm64 only | `XCB_RELEASE` builds `ARCHS=arm64`; the cask declares `depends_on arch: :arm64` | Every Mac with a notch is Apple silicon, so an Intel slice would never run the product it exists for (the synthetic tab alone is not the pitch). TDLib's static library dominates the binary: the DMG is 30 MB arm64-only against 62 MB universal. Going universal is dropping `ARCHS=arm64` and the cask's `depends_on arch:`. |
| D45 | Demo mode + docs media | `NOTCHGRAM_DEMO=1` (Debug builds only) runs the real UI over fictional fixture content delivered through `TelegramSession.injectUpdate` and `MessageRepo`'s offline history hook: no TDLib client, no Keychain, no network, its own preference suite and a throwaway account root, UI pinned to English. Pictures are drawn procedurally (`DemoArtwork`). `make media` (`scripts/capture-media.sh`) regenerates `docs/media/` from it, with the bridge's `setBackdrop`/`openMedia`/`closeMedia` staging the shots | README media of a chat client otherwise means screenshots of someone's real chats. Demo mode makes them reproducible and leak-proof by construction, and exercising the real views (not mock-ups) keeps the pictures honest. It is part of the D43 Release gate: demo markers in a Release binary fail `make verify-release`. |

## Known signing/TCC facts (do not rediscover)
- `security find-identity -v -p codesigning` reports **two valid identities**
  on the author's Mac: an `Apple Development` and a `Developer ID Application`
  certificate. *(This corrects an earlier note here claiming 0 identities —
  verified 2026-08-23.)*
- Signing is **profile-free**: no provisioning profiles exist on disk and none
  are needed, because the app is unsandboxed and uses no App-ID-scoped
  entitlement. Do **not** pass `-allowProvisioningUpdates` — it adds a network
  and Xcode-Accounts dependency and can hang an unattended build.
- Bundle ID is part of TCC identity: freeze `com.f1lcry.notchgram` from the
  first build. MVP needs no TCC-gated permissions in the **app** (network,
  Keychain and user notifications only). The **harness** is a separate
  question: `screencapture` and `CGEventPost` are gated on the *calling*
  process, and both grants are in place today (`CGPreflightScreenCaptureAccess`
  and `AXIsProcessTrusted` return true) — `scripts/preflight.sh` asserts them.
- `NSScreen.cgDirectDisplayID` is **Optional** (`CGDirectDisplayID?`) on macOS 26 —
  a screen mid-reconfiguration has no id yet. Unwrap it; do not force it.
- TDLibKit's generated API is documented against the pinned tag in
  [reference/tdlibkit-api.md](reference/tdlibkit-api.md). **That file is the
  authority for call shapes** — tutorials and pre-1.8.6x snippets are stale.
- **Telegram test-DC reachability is network-dependent.** From the founder's
  network, test **DC 3 times out** while DC 1 and DC 2 answer in ~1 s. The ITest
  harness therefore tries each DC in turn, bounds every step with a deadline,
  and remembers the last DC that worked in `.artifacts/itest/preferred-dc` — so
  it self-heals rather than encoding one network's blocklist.
- `UNUserNotificationCenter.requestAuthorization` currently fails with
  "Notifications are not allowed for this application" for the **Debug** build
  launched from `build/Build/Products/Debug`. CP1's ping has a grant-free
  fallback by design; re-check against the `/Applications` Release copy at M4.
- Ship with **no `.entitlements` file** plus `ENABLE_HARDENED_RUNTIME: YES`.
  Adding App Sandbox / iCloud / Push / App Groups / a Keychain access group is
  what would force a registered App ID and provisioning profiles.

## Planned repo layout

```
notchgram/
├── project.yml            # XcodeGen manifest (source of truth for targets)
├── Makefile               # build / run / test / itest / login / install / screenshot
├── Sources/
│   ├── App/               # lifecycle, DI, Secrets.generated.swift (gitignored)
│   ├── NotchShell/        # window engine (ported Dictate pattern)
│   ├── TelegramCore/      # TDClient, AuthFlow, registry, repos, FileStore
│   ├── Features/          # SwiftUI: auth, chat list, chat, search, settings
│   └── DebugBridge/       # DEBUG-only control channel
├── Tests/
│   ├── Unit/              # state machines, repos over mocked transport
│   └── UITests/           # XCUITest smoke (secondary to DebugBridge flow)
├── ITest/                 # headless test-DC integration harness (CLI target)
├── scripts/               # preflight.sh, gen-secrets.sh, helpers
├── docs/                  # this documentation
└── .artifacts/            # screenshots, logs, evidence (gitignored)
```
