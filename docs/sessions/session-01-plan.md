# Session 1 — implementation plan (NotchGram v0.1.0)

## Context

`docs/sessions/session-01-mvp.md` is already the session *contract*: mission, milestones
M0–M11, verification gates, acceptance checklist, reuse map, fallback playbook. **It stays
the contract.** This plan is the layer beneath it — it resolves the unknowns the brief left
open (with verified answers, not "investigate X"), re-sequences the risks that can sink the
build, and names the files, types and TDLib calls each milestone produces.

Everything below marked *verified* was checked against a primary source during planning
(local probe, SDK header, `td_api.tl` at the pinned commit, or the TDLibKit tag's own
source). Where this plan changes the brief or ARCHITECTURE.md, it says so in
**Deltas** — the executing session amends those docs rather than silently diverging.

---

## 1. Verified environment (probed, not assumed)

| Fact | Value |
| --- | --- |
| macOS / Xcode / Swift | 26.6 (25G72) · 26.6 (17F113) · 6.3.3 · SDK macOS 26.5 |
| xcodegen | 2.46.0 |
| Chip | Apple M5 Pro |
| `.env` | `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` present |
| git | `github.com/f1lcry/notchgram`, private, only `main` |
| **Screen Recording TCC** | **granted** — `CGPreflightScreenCaptureAccess()==true`; `screencapture -l <wid>` returned a real 1080×693 / 236 KB PNG; window *names* readable |
| **Accessibility TCC** | **granted** — `AXIsProcessTrusted()==true` |
| **Signing identities** | **two exist**: an `Apple Development` and a `Developer ID Application` certificate (the author's). No provisioning profiles on disk; signing is profile-free. |

### Measured display topology

| Display | Frame (pt) | Notch |
| --- | --- | --- |
| Built-in Retina | `(0,0,1728,1117)` @2x | **yes** — `safeAreaInsets.top=32`, `auxTopLeft=(0,1085,771,32)`, `auxTopRight=(956,1085,772,32)` → **notch rect `x 771…956` (w 185) × `y 1085…1117` (h 32)**, centred on 864 = width/2 |
| `S6-L` | `(-1080,0,1080,1920)` @1x | no (aux areas `nil`) — portrait |
| `S6-R` | `(1728,37,1920,1080)` @1x | no |

**Three displays are attached right now.** Both the synthetic-notch path and the
multi-display path are live-testable with zero hardware changes — and the pointer usually
lives on an external screen, so *synthetic mode is the primary dev surface*, not a fallback.

### Consequences the brief had not accounted for

1. L3 verification (per-window screenshots + CGEvent/`CGWarpMouseCursorPosition` hover) runs
   **unattended**. No extra founder permission checkpoint at CP0. But the grants belong to the
   *host process* (this terminal), so `scripts/preflight.sh` must assert both and hard-fail.
2. ARCHITECTURE.md's "Known signing/TCC facts" claim that `security find-identity` shows **0
   identities is factually wrong today** — two identities exist. An agent trusting that note
   will mis-diagnose a signing failure. Must be corrected.

---

## 2. Founder decisions taken during planning

| # | Question | Decision |
| --- | --- | --- |
| P1 | git autonomy | **Full autonomy per the brief.** Branch `session-01-mvp`, push per milestone; on a green acceptance checklist the agent merges to `main`, pushes, tags `v0.1.0`, runs `make install`. This explicitly overrides the global "never push to main" rule **for this session only**. |
| P2 | external display | Founder **frequently works on an external, notch-less display.** Synthetic notch + multi-display policy are **MVP scope**, expanding M3. |
| P3 | visual language | **Closer to Telegram Desktop** — message bubbles with in/out alignment, blue accent, familiar chat-list density. Budget real UI work in M5–M7. |

---

## 3. Resolved unknowns

### 3.1 TDLib binding — D1 holds, pin exactly

- **Pin `TDLibKit` `exactVersion: "1.5.2-tdlib-1.8.66-022d6020"`** — the newest release
  (published 2026-08-23; the next-newest `…-d8d46dfa` is 2026-07-17). Wraps **TDLib 1.8.66**.
  `td_api.tl` at both commits is byte-identical to tdlib/td master (16109 lines), so every API
  name below is current either way.
- **All TDLibKit tags are semver *prereleases***, so SwiftPM range requirements (`from:`,
  `majorVersion:`) resolve to **nothing**. `exactVersion:` or `revision:` are the only working
  forms. Fallback pin: `revision: 85ceb00029c4cca943611708299df3ceed4000d2`.
- Dependency graph is two nodes: `TDLibKit` → `TDLibFramework` (`.exact("1.8.66-022d6020")`)
  → remote `binaryTarget` zip, **359,822,073 bytes (343 MiB)**. XcodeGen only emits the
  `TDLibKit` package reference; the binary target is resolved by SwiftPM inside xcodebuild.
- **The xcframework is a *static* framework** (`MACH_O_TYPE: staticlib`, `product: .framework`;
  slice `macos-arm64_x86_64` present). Therefore: `embed: false`, **nothing to embed or
  re-sign**, and a command-line `tool` target can link it directly — which is what makes the
  ITest CLI viable. (Do not add an Embed Frameworks phase; do not chase `@rpath` errors.)
- `TDLibClientManager` **already exists** and already owns the single `td_receive` thread —
  do not write one. API: `init(logger:)` (starts the receive loop), `createClient(updateHandler:
  @escaping (Data, TDLibClient) -> Void) -> TDLibClient`, `closeClients()`. Routing is by
  `@client_id`, so D9 multi-account works as designed. `TdClientImpl` is **deprecated** — any
  tutorial using it is stale.
- The update channel is a **callback delivering raw `Data` on a per-client serial queue**, not
  an `AsyncStream`. Decode with `try client.decoder.decode(Update.self, from: data)`. Bridging
  to an `AsyncStream` and fanning out is our job.
- **HAZARD — `closeClients()` busy-waits** (`while (!clients.isEmpty) {}`) and runs from
  `deinit`. A client that never reaches `authorizationStateClosed` spins a core forever. Never
  call it on the termination path or in itest teardown; send `close` per client and await
  `.authorizationStateClosed` with a timeout.
- **Zero `Sendable`** anywhere in TDLibKit; `TDLibClient` is a plain class. Strategy in §3.6.
- TDLibKit's CI validates macOS on **Xcode 16.4 / macOS 15**, not 26.6 — "it links and signs
  under Xcode 26.6" is unproven and is an explicit M0 gate. Precedent exists for a macOS
  codesign failure caused by a broken `Versions/Current` symlink in the artifact (TDLibKit
  issue #54): if codesign fails, inspect the bundle structure, **not** the certificates.
- Fallback cost is **much higher** than the brief implies: Homebrew `tdlib` is stuck at
  **1.8.0 (Jan 2022)**, ~66 scheme revisions behind. A `libtdjson` bridge means
  `brew install --HEAD` (long C++ build) + hand-written Codable envelopes + openssl vendoring
  and `install_name_tool` rewrites for a hardened-runtime bundle. Realistically 1–3 days.
  Treat it as a genuine emergency exit, not a cheap plan B.

### 3.2 Test DC — exact contract (D13 confirmed)

- Numbers are `99966XYYYY`, **X ∈ 1…3** (DC id), YYYY random. Code = **X repeated five
  times** (`9996621234` → `22222`). *Do not hardcode 5* — read the length from
  `authorizationStateWaitCode.codeInfo.type` where the case carries `length`, else default 5.
- `setTdlibParameters` has **exactly 14 fields**; the brief's mental model omitted three:
  `database_encryption_key` (this is where D6's Keychain key goes — `setDatabaseEncryptionKey`
  only *changes* an existing key), `use_file_database`, `use_chat_info_database`.
  TDLibKit's Swift params are **alphabetical and all Optional**.
- `useTestDc: true` is the **only** switch needed — TDLib compiles in the test DC addresses.
- The production `api_id`/`api_hash` work against the test DC (structural evidence from
  `Td.cpp`; upgraded to verified the first time itest reaches `Ready`).
- **A fresh number is unregistered → `authorizationStateWaitRegistration` is the NORMAL
  path.** A harness handling only waitCode→ready hangs forever. Answer with
  `registerUser(disableNotification:false, firstName:"NotchGram", lastName:"ITest")`.
- Saved Messages needs no setup: `getMe()` → `createPrivateChat(force:false, userId: me.id)`.
- **Flood limit ≈ 5 logins/day/number.** Design rule: randomize YYYY **every run**, fresh
  `database_directory` under `.artifacts/` per run, never reuse or checkpoint test-DC state
  (Telegram periodically wipes it). On `FLOOD_WAIT_N` with N > 60 → regenerate YYYY, don't sleep.
- Cosmetic gotcha to not debug later: TDLib appends `", TDLib <version>"` to
  `application_version` server-side for any api_id ≠ 21724.

### 3.3 Keyboard focus — **the project's biggest risk is retired**

Verified live on this machine (compiled probe, not inference): a borderless
`.nonactivatingPanel` `NSPanel` with `canBecomeKey → true`, hosting a SwiftUI `TextField` in an
`NSHostingView`, in an `.accessory` app — **clicking it makes it key, synthetic keystrokes land
in the field, and `NSWorkspace.frontmostApplication` never changes.** Focus *restore* is a
non-problem: nothing was displaced. Esc = `panel.makeFirstResponder(nil)`.

Consequences:

- **Never call `NSApp.activate()`.** Treat `NSApp.isActive` as meaningless (it flips true while
  the panel is key); use `panel.isKeyWindow` as the focus predicate.
- SwiftUI's TextField is backed by a real field editor (`_SystemTextFieldFieldEditor`, an
  `NSTextView`), so IME / ⌘V / ⌘A / selection all work — **no custom NSTextView bridge needed**.
- `@FocusState` no-ops while the window isn't key. Order: `makeKeyAndOrderFront(nil)` **first**,
  then set the focus binding (one runloop hop later).
- `becomesKeyOnlyIfNeeded` is effectively a **no-op** with `NSHostingView`: hit-testing returns
  the hosting view at every point and it reports `needsPanelToBecomeKey = true` unconditionally.
  So *any* click in the panel takes key. Acceptable; if selective focus is ever wanted, the only
  lever is an `NSHostingView` subclass overriding `needsPanelToBecomeKey`.
- Dictate is **no precedent here** — it has zero text input in the notch and its explicit design
  goal is to never take focus. This is new ground, now de-risked.

### 3.4 Dictate port map (files to copy / adapt / rewrite)

Source: Dictate's `Sources/` tree (the author's earlier app; main checkout only,
not its worktrees).

| File | Verdict |
| --- | --- |
| `Notch/NotchShape.swift` (59 l) | **copy as-is** — pure `Shape`, `AnimatablePair` on both radii (must interpolate or corners snap on frame 1) |
| `Notch/FullScreenProbe.swift` (62 l) | **copy as-is** — `CGWindowListCopyWindowInfo` *bounds only*, so no Screen Recording consent needed |
| `Notch/NotchGeometry.swift` (209 l) | **copy + 5 adaptations** — see below |
| `Notch/NotchController.swift` (480 l) | **copy skeleton + 6 adaptations** — keep the whole poll / coverage / Space-repair machinery |
| `Notch/NotchView.swift` (308 l) | **copy the ~30-line shell, rewrite the ~220 lines of Dictate UI** |
| `UI/EditShortcutMonitor.swift` | **copy as-is — mandatory.** LSUIElement apps have no main menu, so ⌘C/⌘V/⌘X/⌘A never reach text views. It keys on *physical* key codes so shortcuts survive ЙЦУКЕН. Without it, paste-into-composer silently does nothing. |
| `UI/GlassBackdrop.swift` | **copy as-is** — `NSVisualEffectView` with `state = .active` pinned, because SwiftUI materials dim to flat grey when the window isn't key (our normal state) |
| `Engine/AppSettings.swift` | **copy the pattern** — `@Observable` + injected `UserDefaults` + `didSet` persistence |
| `UI/Settings/GeneralSettingsTab.swift` login-item block | **copy the pattern** — `SMAppService.mainApp`, surface `.requiresApproval`, poll `status` on a 1 s loop |
| `AppDelegate.swift` XCTest early-return guard | **copy as-is** — unit tests must never spawn desktop panels |
| GlassIconButton / RecordButton / ClipboardHistory / License / Sparkle / MainWindowBridge | **skip** |

**Load-bearing details to port verbatim, comments included** (each is a fixed bug):

- **Hover is polled, never tracked.** No `NSTrackingArea`, no SwiftUI `.onHover` (scoped to the
  active app, dead for a background app). Tracking areas lose the pointer pressed against the
  screen top → no `mouseExited` → stuck panel. Timings: `dwell 150ms`, `grace 250ms`,
  `idlePoll 80ms`, `openPoll 40ms`, `settleDelay 450ms`, `foldDelay 700ms`, housekeeping every 8 ticks.
- **`NSRect.contains` excludes the max edge** and a pointer at the screen top reports exactly
  `maxY` — hit-test the inflated `trigger` rect (`x−6, w+12, h+slack+4`), never the raw notch.
- **The window never changes frame.** All motion is a SwiftUI spring
  (`.spring(response: 0.38, dampingFraction: 0.86)`) inside a still window, `.clipShape`d to the
  slab. Animating the frame of the window that owns the hover target makes it oscillate and chase
  the pointer. **A panel-size change (D8) is therefore a full `rebuild()` while collapsed, never a
  `setFrame`.**
- **`canJoinAllSpaces` membership decays over a session** — panels quietly fall off desktops.
  Repair: gate on `!panel.isOnActiveSpace`, then `orderOut(nil)` **then** `orderFrontRegardless()`
  (ordering front alone is a no-op). Driven by `activeSpaceDidChangeNotification` + every 8th tick.
- **Physical-notch alpha dance**: folded panel is `alphaValue = 0` (a Space switch is the one
  moment the black slab leaves the cut-out); restored to 1 *before* the unfold starts, dropped to
  0 only *past* `foldDelay`. Synthetic tabs stay at alpha 1.
- **`ignoresMouseEvents = true` while collapsed** is what hands the menu bar back.
- Window recipe: `NSPanel([.borderless, .nonactivatingPanel])`, `hidesOnDeactivate = false`
  (load-bearing — NSPanel hides on app deactivation by default), `isFloatingPanel = true`,
  `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`,
  `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, `isMovable = false`,
  `orderFrontRegardless()` (never `orderOut` mid-animation).
- **`latched` already *is* indefinite pinning** — do not invent a `pinned` flag. Rename to
  `pinnedHost`; swap the driver from `isDictating` to composer-focused / context-menu-open /
  drag-in-flight / DebugBridge-force-expand.

**Three assumptions that break at 880×580** (Dictate's panel is 420×178):

1. `hold` = the whole panel rect → any pointer anywhere in 880×580 holds it open. Fine, but the
   pin is what matters while typing with the pointer parked outside.
2. `level = .statusBar` sits **above** `.mainMenu`, so an expanded 880-wide panel with
   `ignoresMouseEvents = false` swallows clicks across most of the menu bar. → carve the top
   strip's flanks out of the hit region (see M3).
3. Content is always laid out at full size and merely hidden with `.opacity(0).blur(5)`. For a
   live TDLib chat list that means continuous rendering while folded. → **mount content only when
   `expanded || settling`**; unmount past `foldDelay`.

### 3.5 Multi-display + synthetic notch (P2)

- **Dictate already builds one panel per screen** (`NotchGeometry.all()` over `NSScreen.screens`)
  — ARCHITECTURE.md's singular `NotchWindow` does not match the code it says to port.
- **Never use `NSScreen.main`** for detection: it follows the key window. The physical-notch test
  is `auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil`; width =
  `frame.width − left.width − right.width`; height = `safeAreaInsets.top`.
  Using `safeAreaInsets.top > 0` as the *existence* test is the bug boring.notch ships
  (`safeAreaInsets.top` tracks menu-bar visibility, not hardware).
- macOS 26 adds `NSScreen.cgDirectDisplayID` — use it (min macOS 26). Persist any display
  preference by **UUID** (`CGDisplayCreateUUIDFromDisplayID`), never by `CGDirectDisplayID`
  (reassigned on reconfiguration). **Do not gate on "is built-in"** — built-in ≠ notched, and in
  clamshell the built-in is absent from `NSScreen.screens` entirely.
- `didChangeScreenParametersNotification` → `rebuild()` (full teardown + recreate) is the whole
  hot-plug/clamshell story; `CGDisplayRegisterReconfigurationCallback` is not needed. **Add the
  debounce Dictate lacks** — clamshell fires it several times in ~1 s; diff
  `Set(uuid) + Set(frame) + Set(safeAreaTop)` or coalesce on a 150–250 ms trailing timer, or the
  panel visibly flashes 3–5×.
- **Synthetic notch geometry (new decision D14)** — CONCEPT.md says "roughly half the width of a
  real one"; Dictate makes it *full* width, so a naive port silently violates the requirement:

  ```
  realNotchWidth  = first physical cut-out found among screens, else 200
  menuBar(screen) = frame.maxY − visibleFrame.maxY, else 24
  syntheticWidth  = clamp(round(realNotchWidth * 0.5), 88, screen.frame.width * 0.4)   // ≈92pt here
  syntheticHeight = clamp(round(menuBar * 0.5), 10, 16)                                 // ≈12pt
  rect            = (midX − w/2, frame.maxY − h, w, h)
  bottomRadius    = round(h * 0.62)
  ```
  Hover trigger for the synthetic tab must be generous (a 92×12 rect is not hittable):
  `insetBy(dx: −14)`, grow downward 10 and **4 above `frame.maxY`**. Use **`dwell = 250 ms` for
  synthetic** (the trigger overlaps the menu bar; a transit takes ~60–100 ms, so 250 ms still reads
  as immediate but survives reaching for a menu) and keep **150 ms for physical**.
- **Panel clamp per screen** (D8's "screen-safe max", which Dictate never implemented):
  `w = clamp(pref.w, 640, screen.frame.width − 48)`, `h = clamp(pref.h, 420, frame.maxY −
  visibleFrame.minY − 16)`, x clamped into the screen, y pinned to `frame.maxY`. If even the
  640×420 floor doesn't fit, **still create the panel** and let it clip — a missing tab reads as a
  crash. (Top edge uses `frame`, not `visibleFrame` — the slab is meant to overlap the menu bar.)
- **Exactly one panel expanded at a time**, via Dictate's existing `latched` handoff. Per-screen
  state holds only `expanded / settled / pointerInside / isCovered`; everything else
  (`ChatRepo`, active chat, **composer draft**, scroll anchor) lives in shared `@MainActor`
  stores. *Composer draft must live in the shared store or a hot-plug `rebuild()` silently eats a
  half-typed message* — a new failure mode Dictate doesn't have.
- **Fullscreen conflict (new decision D22).** Dictate's `refreshCoverage()` orders *synthetic*
  panels **out** when a fullscreen window covers the display, which directly contradicts the
  acceptance item "panel appears over a fullscreen app's Space" — and it passes on the built-in
  only because physical hosts are exempt. Resolution: on `isCovered`, set `alphaValue = 0` +
  `ignoresMouseEvents = true` **instead of `orderOut`**, and skip the `!isCovered` guard when the
  expand comes from a non-hover source. Amend the checklist to "panel can be **summoned** over a
  fullscreen app's Space".
- **Virtual displays are a dead end** — `displayplacer` can't create displays, BetterDisplay needs
  a running GUI app, `CGVirtualDisplay` is private API. Don't open that branch; the three real
  displays plus unit fixtures cover it.

### 3.6 Swift 6 strict concurrency

TDLibKit declares `swift-tools-version:5.3`, so **the package itself compiles in Swift 5 mode and
will build clean** — all friction is at NotchGram's call sites. Plan:

- One file `Sources/TelegramCore/TDLibKit+Sendable.swift` with
  `extension X: @retroactive @unchecked Sendable {}` for the value types actually crossed:
  `Update, Chat, Message, File, ChatPosition, ChatFolderInfo, ChatNotificationSettings,
  ConnectionState, AuthorizationState`. All are structs/enums with value-only payloads, so this is
  sound. `@preconcurrency import TDLibKit` scoped to TelegramCore as the belt.
- **Never pass `TDLibClient` (a class) across an actor boundary** — `TDClient` owns it
  (`nonisolated(unsafe)`) and exposes only Sendable results.
- Map TDLib models to NotchGram's own Sendable domain types at the `TDClient` boundary — the repos
  need that mapping anyway.
- Do **not** set `SWIFT_TREAT_WARNINGS_AS_ERRORS` project-wide: `TDLibClientManager` contains a
  literal `#warning(...)` that would become a build failure.
- Decide `SWIFT_DEFAULT_ACTOR_ISOLATION` at M1 (default: **leave unset**, matching Dictate) —
  retrofitting it later rewrites TDClient and the update stream.

### 3.7 TDLib API gotchas that shape the code

| Area | The trap | The rule |
| --- | --- | --- |
| Chat order | `updateChatLastMessage` / `updateChatDraftMessage` may be sent **instead of** `updateChatPosition`, each carrying its own `positions` array | Route all three through one `applyPositions(chatId:positions:)`. Sort by `(position.order, chat.id)` descending; `order == 0` means remove. `order` is `TdInt64` → sort on `.rawValue`. Pinned chats are ordinary entries with `is_pinned == true`, not a separate array. Drive the UI from `chat.positions`, never `chat.chat_lists`. |
| History | First `getChatHistory` on a cold cache officially returns 0–1 messages | **Loop**: re-issue with `from_message_id` = oldest received, `offset 0`, until enough or a response returns 0 (the documented end-of-history signal). Cap ~10 iterations. Paint instantly with `only_local: true`, then backfill. |
| Live messages | In supergroups/channels updates arrive **only for opened chats** | `openChat` on entering a conversation, `closeChat` on leaving/collapse, re-open on re-expand. |
| Message gaps | `updateChatLastMessage.last_message == nil` means a **gap**, not an empty chat | Treat as "refetch this chat's tail". |
| Optimistic send | `sendMessage` returns a temporary id; `updateMessageSendSucceeded(message, old_message_id)` replaces it and "almost any field can be different" | Key rows by a stable local key; use `messageSendOptions.sending_id` as the correlation token; replace the whole object, don't patch the id. Server ids are `server_id << 20`, so `id % 1048576 == 0` tests "is a real server message". |
| Delete | `updateDeleteMessages(..., from_cache:)` | `from_cache == true` means cache eviction — the message can come back. Only `is_permanent` is a real delete. |
| Read state | There is no per-message read update | Render ticks by comparing `message.id <= chat.last_read_outbox_message_id`; re-evaluate visible outgoing rows when it moves. Mark read with `viewMessages(..., force_read: true)` — essential for a panel that is usually "closed". |
| Entity cache | `updateNewChat` / `updateUser` are guaranteed to arrive **before** the id is handed to the app | Never call `getChat`/`getUser` to resolve an id — cache from updates. |
| Update ordering | "All updates and responses must be handled in the order received" | One `AsyncStream` drained by **one sequential loop**. Per-update `Task { await repo.apply(u) }` destroys ordering and corrupts chat order / counters. |
| Requests | `queryQueue` is **concurrent** — two `td_send`s can reorder | Await each response before issuing a dependent request. |
| Auth | `AuthorizationState` has **13 cases**, not 5 (incl. `WaitRegistration`, `WaitEmailAddress`, `WaitEmailCode`, `WaitOtherDeviceConfirmation`, `WaitPremiumPurchase`) | Model all 13 with an explicit `unsupported(String)` UI leaf. A surprise state during CP1 — the founder's one interactive login — must degrade to a readable screen, not a hang. |
| `sendMessage` arity | 1.8.66 added `topicId: MessageTopic?`; `inputMessagePhoto` now nests an `InputPhoto` wrapper | Any pre-1.8.6x snippet will not compile. Pass `topicId: nil`. |
| Typing | `updateUserChatAction` **does not exist** in 1.8.66 | It is `updateChatAction(chat_id, topic_id, sender_id, action)`. Re-send `sendChatAction` ~every 5 s. |
| Folders | `chatFilter*` is fully gone | `chatFolder*`. `updateChatFolders(chat_folders, main_chat_list_position, are_tags_enabled)` delivers the whole tab bar — insert `chatListMain` at `main_chat_list_position`. Tab label is `folderInfo.name.text.text`. Folder content = `loadChats(chatListFolder(id))` + the same position sorting, **not** `included_chat_ids` (those are the folder's *rules*). |
| Files | `local.path` "may be empty" and can point at a partial file | Render only when `local.is_downloading_completed == true` **and** path non-empty. Use `downloadFile(synchronous: false)` + `updateFile` for UI (synchronous stalls the actor). `updateFile` carries both download *and* upload progress. Render `minithumbnail` (inline JPEG bytes) immediately as the zero-latency placeholder. |
| Media decode (verified locally) | — | **webp stickers decode natively** (`org.webmproject.webp` in ImageIO). **`stickerFormatWebm` is unplayable** — AVFoundation has no webm/matroska UTI on 26.6 → fall back to `sticker.thumbnail`. TGS is gzipped Lottie → T3. GIFs are usually `video/mp4` → AVPlayer looping; branch on `mime_type`. |
| Voice notes (verified locally) | `AVURLAsset` sniffing is **extension-dependent** for Ogg (no extension → `isPlayable=false`, 0 tracks) | Use **`AVAudioPlayer(contentsOf:)`** — worked in all cases including no extension (105.77 s Ogg/Opus opened fine); `AVAudioFile` gives 48 kHz Float32 frames for a waveform. Reserve `AVPlayer` for mp4. |
| Notifications | Naive `mute_for` reading notifies muted chats | `chatNotificationSettings.use_default_mute_for` makes `mute_for` meaningless — resolve against `updateScopeNotificationSettings` for the three scopes. |
| Shutdown | see §3.1 | Send `close`, await `.authorizationStateClosed` with a ~5 s timeout **off** the main actor, then terminate. |

### 3.8 Build, signing, secrets, harness

- **Static framework ⇒ `embed: false`**, and the ITest `tool` target links it with no copy phase.
- **`make deps` is a separate target** running `xcodebuild -resolvePackageDependencies`. Never let
  the 343 MB download happen implicitly inside `make build` — an agent will read it as a hang.
  Start it in the background as the very first action of M0.
- **`-clonedSourcePackagesDirPath` on every xcodebuild invocation** (put it in one shared `$(XCB)`
  make variable — never write a bare `xcodebuild` line). Dictate's `clean: rm -rf build` would
  otherwise delete the 343 MB artifact, because `SourcePackages` lives inside `-derivedDataPath`.
  Because the session runs in a **git worktree**, point it at a shared location outside the repo —
  `SPM_DIR ?= $(HOME)/Library/Caches/NotchGram/spm` — so a worktree (or a `make clean`) never costs
  a second 343 MB download. Still add `.spm/` to `.gitignore` for anyone who overrides it locally.
- **Secrets order matters**: XcodeGen resolves source globs at *generate* time, so
  `make generate` = `gen-secrets.sh` **then** `xcodegen generate`; also declare
  `Sources/TelegramCore/Secrets.generated.swift` (moved there in M1 — the ITest
  `tool` target compiles TelegramCore but nothing from `Sources/App`).
  Keep values out of logs with the XcodeGen build-script key **`showEnvVars: false`** *and* the
  xcodebuild flag **`-hideShellScriptEnvironment`**; script side: no `set -x`, `umask 077`, echo
  lengths not values, write to a temp file and `cmp -s` before `mv` (rewriting identical content
  still bumps mtime and forces a full module recompile).
- **Signing (amends D11).** Two identities exist and profile-free signing works. Do **not** pass
  `-allowProvisioningUpdates` (adds a network/Xcode-Accounts dependency and a possible unattended
  hang) and do not pass `CODE_SIGN_IDENTITY` on the command line for Debug.
  **Debug = Apple Development (automatic). Release = Developer ID Application; `/Applications`
  only ever receives the Release build.** Rationale: alternating leaf certificates changes the
  code requirement, which invalidates `SMAppService` login-item registration and can re-trigger
  TCC prompts — the acceptance checklist has a launch-at-login item that would silently fail.
  Assert the identity in `make install` (`codesign -dvv | grep Authority`). Fallback if manual
  Developer ID signing fights XcodeGen: keep automatic signing and re-sign the Release bundle
  in place with `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"`
  (Dictate's `make dmg` already does exactly this).
- **Ship with no `.entitlements` file** + `ENABLE_HARDENED_RUNTIME: YES`. The MVP needs generic
  Keychain (no access group), outbound network and user notifications — none require entitlements.
  Adding App Sandbox / iCloud / Push / App Groups / a Keychain access group is what would force a
  registered App ID and provisioning profiles.
- **`xcresulttool` on Xcode 26.6** (verified, version 24757): the old
  `xcrun xcresulttool get --format json` is deprecated and now needs `get object --legacy`.
  Use `xcrun xcresulttool get test-results summary --path X.xcresult --compact`,
  `… get test-results tests …`, `… get build-results …`. `-resultBundlePath` fails if the path
  exists → `rm -rf` it first. Neither xcpretty nor xcbeautify is installed; `-quiet` +
  `-resultBundlePath` + xcresulttool is the complete machine-readable story.
- **Never `pkill` NotchGram.** TDLib holds an encrypted SQLite open; a SIGKILL risks DB corruption,
  and a corrupt DB after CP1 means a re-login — i.e. burning a founder checkpoint. Quit order:
  DebugBridge `quit` (calls `NSApp.terminate`) → `osascript -e 'quit app id …'` →
  `pkill -TERM` after a 10 s timeout → never `-9`.
  (`osascript` can also raise a one-time Automation TCC dialog, which is why DebugBridge is first.)
- **Unattended run + logs**: `open -n -g -o <abs>/run.out.log --stderr <abs>/run.err.log <App.app>`.
  `open -a` loses the streams; executing `Contents/MacOS/NotchGram` directly keeps them but skips
  LaunchServices registration (breaking `open notchgram://`). Pair with `os.Logger` +
  `log stream --predicate 'subsystem == "com.f1lcry.notchgram"'`.
- **DebugBridge transport (new decision D18): a loopback HTTP listener on 127.0.0.1, compiled into
  *all* configurations but inert unless explicitly enabled.**
  The decisive constraint is reading status back *synchronously from one shell command*: a URL
  scheme is fire-and-forget, and `DistributedNotificationCenter` has no reply primitive (a `make`
  recipe has no listener process). No entitlement or prompt is needed because the app is
  unsandboxed. `GET /status` → JSON; `POST /command` → returns the **post-transition** state so the
  agent never races the 450 ms unfold spring. Write the port to
  `~/Library/Application Support/NotchGram/debug-port` so the harness can discover it and detect
  "app not running" (connection refused). Keep the `notchgram://` scheme as a secondary, human path.
  **Why not DEBUG-only:** M8's launch-at-login item and M10's L4 real-account probe both have to
  run against the `/Applications` copy — which under D20 is the Developer ID *Release* build,
  because `SMAppService` registration binds to the app's path and alternating leaf certificates is
  exactly what D20 exists to prevent. A DEBUG-only bridge would leave the agent unable to drive the
  only build those milestones may test. So: present in Release, listener started only when
  `defaults read com.f1lcry.notchgram DebugBridgeEnabled` is true or `NOTCHGRAM_DEBUG_BRIDGE=1` is
  set; bound to `127.0.0.1` only; off by default for the founder's daily use.
- **Screenshots**: `screencapture -x -o -l <windowNumber>` (window id from `GET /status`, which
  returns `NSWindow.windowNumber`). Also implement an in-app `ImageRenderer` /
  `NSView.cacheDisplay(in:to:)` capture over DebugBridge as the robust fallback — it needs **no TCC
  at all** and captures the panel even when occluded. `make screenshot` must assert `test -s`.
- **Hover synthesis**: `CGWarpMouseCursorPosition` is enough and needs **no** Accessibility grant —
  because our hover detection *polls* `NSEvent.mouseLocation`, a bare warp triggers expansion with
  no event synthesis. `CGEventPost` (Accessibility-gated, already granted) is only needed for
  clicks and keystrokes.
- **Notification authorization is a hidden 4th founder touch.** CP1 is delivered *by* a push
  notification, which silently depends on a `UNUserNotificationCenter` grant that doesn't exist
  yet. Request it in **M0**, and give the CP1 ping a grant-free fallback in parallel
  (`osascript -e 'display notification'` / terminal bell / a status file).

---

## 4. Module and file map

```
Sources/
├── App/
│   ├── NotchGramApp.swift            @main + NSApplicationDelegateAdaptor
│   ├── AppDelegate.swift             lifecycle, DI wiring, UN authorization, XCTest guard,
│   │                                 graceful TDLib shutdown on terminate
│   ├── AppEnvironment.swift          DI container (TDClient, repos, settings, notch controller)
│   ├── LoginItem.swift               SMAppService.mainApp wrapper (+ .requiresApproval)
│   └── Secrets.generated.swift       gitignored, produced by scripts/gen-secrets.sh
├── NotchShell/
│   ├── ScreenInfo.swift              Sendable value type + GeometrySettings (the testability seam)
│   ├── ScreenProvider.swift          protocol + LiveScreenProvider + FixtureScreenProvider
│   ├── NotchGeometryEngine.swift     PURE: [ScreenInfo] × settings -> [NotchGeometry]
│   ├── NotchGeometry.swift           ported struct (physical/synthetic, trigger/hold/collapsed)
│   ├── NotchPanel.swift              NSPanel subclass, canBecomeKey -> true
│   ├── NotchController.swift         ported: poll loop, hosts, rebuild, Space repair, pinnedHost
│   ├── NotchShape.swift              copied as-is
│   ├── FullScreenProbe.swift         copied as-is
│   ├── NotchChromeView.swift         the ~30-line shell of NotchView + top-strip notch cut-out
│   └── FocusCoordinator.swift        Esc release, pin-while-key, composer focus ordering
├── TelegramCore/                     (must never import AppKit/SwiftUI — preflight greps for it)
│   ├── TDTransport.swift             owns TDLibClientManager + createClient + Data->Update decode
│   ├── TDClient.swift                actor: typed async requests, ordered update fan-out
│   ├── TDLibKit+Sendable.swift       retroactive @unchecked Sendable conformances
│   ├── TDError.swift                 TDLibKit.Error mapping (it shadows Swift.Error)
│   ├── AuthFlow.swift                all 13 authorization states + unsupported(String) leaf
│   ├── AccountRegistry.swift         accounts, per-account db dirs, useTestDc flag
│   ├── KeychainStore.swift           256-bit db key per account (D6)
│   ├── ChatRepo.swift                @MainActor: applyPositions(), ordering, unread, folders
│   ├── MessageRepo.swift             @MainActor: windows, history loop, send pipeline, read state
│   ├── SendPipeline.swift            optimistic send, sending_id correlation, temp->real remap
│   ├── FileStore.swift               downloadFile + updateFile progress -> local paths
│   └── Models/                       Sendable domain types (ChatSummary, MessageItem, …)
├── Features/
│   ├── Common/Theme.swift            Telegram-Desktop-like palette, bubble metrics, density
│   ├── Common/AvatarView.swift       minithumbnail placeholder -> downloaded small photo
│   ├── Auth/                         PhoneEntry, CodeEntry, Password, Registration, Unsupported
│   ├── ChatList/                     ChatListView, ChatRowView, FolderTabsView, ConnectionBanner
│   ├── Chat/                         ChatView, MessageList, MessageBubble, Composer, DateSeparator
│   ├── Media/                        Photo, Sticker, Animation(GIF), VoicePlayer, VideoThumb
│   ├── Search/SearchView.swift
│   ├── Settings/SettingsView.swift   panel size, collapsed badge (D10), launch at login, logout
│   └── Profile/ProfileView.swift
└── DebugBridge/                      DEBUG only
    ├── DebugServer.swift             127.0.0.1 listener, port file
    ├── DebugCommand.swift            expand/collapse/setSize/gotoAuthState/openChat/
    │                                 forceSynthetic/screenshot/quit/status
    └── DebugStatus.swift             JSON: auth, connection, panel state+frame, windowNumber,
                                      resolved [ScreenInfo] + [NotchGeometry], openChatId
Tests/Unit/                           geometry fixtures, AuthFlow, ChatRepo ordering, SendPipeline
Tests/UITests/                        minimal XCUITest smoke (secondary to DebugBridge)
ITest/                                headless test-DC harness (tool target)
scripts/                              preflight.sh (extend), gen-secrets.sh (new)
```

---

## 5. Milestone plan

Each milestone: implement → verify at its gates → conventional commit → push.
**Every milestone's UI state must be reachable through DebugBridge, never only by hover.**

### M-1 — Land the plan in the repo *(before any code)*

The brief's own delivery model is "session start: read ROADMAP → the active brief" — a build
session reads `docs/`, not `~/.claude/plans/`. Everything expensive in §3 (the exact pin, the
static-framework finding, the 14-field `setTdlibParameters`, the focus recipe, `xcresulttool` on
26.6, `AVAudioPlayer`-not-`AVURLAsset`, webm unplayable) would otherwise be re-derived or gotten
wrong.

1. Create the worktree: `/mkwt session-01-mvp` (per the workspace convention that long work does
   not happen in the main checkout).
2. Land this document at **`docs/sessions/session-01-plan.md`** and commit it (`docs: land session 1
   implementation plan`). *(done — you are reading it)*
3. Apply the §7 amendments to `ARCHITECTURE.md`, `session-01-mvp.md` and `CLAUDE.md`, each
   referencing `session-01-plan.md` as the source of the resolved facts. Commit, push.

### M0 — Scaffold + de-risking spikes  *(the brief's M0, materially expanded)*

The brief's M0 ("empty app builds, signs, launches") defers the two risks that can sink the
session to M1 and M4. Both must be answered in hour one, while the fallbacks are still cheap.

1. **First action**: start `make deps` in the background (343 MB, timed). Do not block other work
   on it; do not clean derived data casually afterwards.
2. `project.yml` — app target `NotchGram` (LSUIElement, `com.f1lcry.notchgram`, the author's team,
   deployment 26.0, `SWIFT_VERSION "6.0"`, hardened runtime, no entitlements file), `NotchGramTests`
   (`bundle.unit-test`, **same CODE_SIGN_STYLE + DEVELOPMENT_TEAM as the app** — a hardened-runtime
   host refuses to dlopen a differently-signed bundle, and it fails at *load* time, not compile),
   `NotchGramUITests`, `ITest` (`type: tool`, sources `Sources/TelegramCore` + `ITest`,
   `- package: TDLibKit` with `embed: false`). `info:` block (LSUIElement, CFBundleURLTypes) —
   XcodeGen writes `Sources/Info.plist`, which must be gitignored.
3. `Makefile` — `deps generate build test uitest itest login run quit install screenshot logs clean
   distclean` with one shared `$(XCB)` variable carrying `-derivedDataPath build
   -clonedSourcePackagesDirPath .spm -destination 'platform=macOS,arch=arm64'
   -hideShellScriptEnvironment -quiet`.
4. `scripts/gen-secrets.sh`; extend `scripts/preflight.sh` with the TCC probes
   (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`), a non-empty `screencapture` assertion,
   and the `grep` guard that `Sources/TelegramCore` imports no AppKit/SwiftUI.
5. Minimal `NotchPanel` + `NSHostingView` with **one `TextField`**, plus DebugBridge v0
   (`/status`, `expand`, `collapse`, `quit`).
6. Request `UNUserNotificationCenter` authorization here (see §3.8).
7. `.gitignore` += `Sources/Info.plist`, `.spm/`.

**Exit gates (all four, or stop and reassess):**
- **G1** `make deps` resolved the pinned tag; record the measured download time and the resolved
  versions.
- **G2** App builds, **links + signs the static TDLibFramework under Xcode 26.6**, launches, and
  prints TDLib's version from `getOption("version")`. *(If codesign fails, inspect the framework's
  `Versions/Current` symlink — not the certificates.)*
- **G3** **Focus spike in the real signed app**: `CGWarpMouseCursorPosition` + `CGEventPost` click,
  then keystrokes → the text appears in the TextField and `GET /status` reports it, while
  `frontmostApplication` is unchanged. *(Verified as a standalone probe already; this confirms it
  holds inside the app bundle.)*
- **G4** `make test` green; `make screenshot` yields a non-empty PNG of the panel window.

Also: **run `make distclean && make build` once** to prove the fresh-clone path (the
`Secrets.generated.swift` ordering trap fails as "cannot find Secrets in scope", which points at
the wrong layer). Gate: L1.

### M1 — TelegramCore foundation
`TDTransport` (single `TDLibClientManager`, `createClient`, `Data → Update` decode, one
`AsyncStream` + fan-out to typed handlers with an explicit buffering policy), `TDClient` actor,
`TDLibKit+Sendable.swift`, `TDError`, `AuthFlow` (all 13 states), `AccountRegistry` +
`KeychainStore` (256-bit key passed **in** `setTdlibParameters`), `useTestDc` as an account
attribute. Set log verbosity to 1 before creating clients. Implement the timeout-bounded shutdown
(never `closeClients()`).
**First 60-second check of M1**: create a client, `setTdlibParameters(useTestDc: true)` with the
real credentials, `setAuthenticationPhoneNumber("99966X….")`, assert `WaitCode` arrives — this
single call confirms or kills the whole test-DC strategy before anything is built on it.
Record TDLibKit tag + wrapped TDLib version + every `@preconcurrency`/`@unchecked Sendable` spot
for the report. Gate: L1.

### M2 — Test-DC integration green
`ITest` harness: fresh random `YYYY` + fresh db dir per run, cold start → `WaitRegistration` →
`registerUser` → `Ready` → `getMe` → `createPrivateChat` → `sendMessage` (UUID payload) → await
`updateMessageSendSucceeded` → `getChatHistory` read-back → small (<1 MB) PNG upload + download →
clean close. Retry shape: 3 attempts max, fresh YYYY each, backoff 2/8/30 s with jitter, hard
per-run wall clock 90–120 s, `FLOOD_WAIT_N > 60` → regenerate rather than sleep, connection not
`Ready` within ~30 s → abort and fall back to the mocked transport (noted in the report).
Also unit-test the *no-registration* branch (the real account will never hit `WaitRegistration`,
the test DC always will — build and test both). Gate: L1+L2.

### M3 — NotchShell  *(expanded by P2)*
Port per §3.4. New work beyond the port: the `ScreenInfo`/`ScreenProvider`/`NotchGeometryEngine`
extraction (pure, injectable — Dictate reads `AppSettings` statically inside the geometry
function, which must become injected `GeometrySettings` or nothing is testable);
synthetic-notch geometry per D14; per-screen panel clamp; `didChangeScreenParameters` **debounce**;
shared-state / per-screen-state split with the composer draft lifted into the shared store;
D22 coverage behaviour; menu-bar hit-region carve-out for the expanded 880-wide panel; content
mounted only when `expanded || settling`; DebugBridge v1 (`expand/collapse/setSize/openChat/
gotoAuthState/forceSynthetic/screenshot/status/quit`).

Unit fixtures (no hardware): notched built-in alone · notched + portrait external (today's real
setup) · **external only (clamshell)** · two notch-less externals · 800×600 tiny screen ·
600×1920 narrow · zero screens · `safeAreaTop == 0` with non-nil aux areas · mirrored/duplicate
frames · reconfig diffing (rebuild fires exactly once per real change, zero times for an identical
snapshot). Gate: L1+L3.

### M4 — Auth UI → **CP1**
Phone → code → 2FA → registration → ready, error states, logout; every one of the 13 states has a
screen (unsupported ones show the raw state name + copy-diagnostics). Verified end-to-end on a
test-DC account **through the real panel UI**, every screen reached via DebugBridge
`gotoAuthState` and screenshotted. QR login is deliberately **out** of the MVP (CP1 exists to
dogfood phone/code/2FA). Then fire CP1 — push notification **plus** the grant-free fallback ping.
Keep building on test-DC accounts while waiting; only M10 hard-depends on CP1. Gate: L1–L3.

### M5 — Chat list (T1)
`loadChats(chatListMain)` + the unified `applyPositions` path; pinned section; avatars
(minithumbnail → downloaded `small`); last-message previews per content type; unread + mention
badges; mute state; live reorder; connection-state banner (5 states, `Updating…` ≠ `Connecting`).
`Theme.swift` and the Telegram-like row metrics land here (P3). Use `ScrollView + LazyVStack`
(not `List` — NSTableView-backed, fights a dark borderless slab and reuses badly with
variable-height rows). Gate: L1–L3.

### M6 — Conversation (T1)
`openChat`/`closeChat` bracketing; the history **loop**; `only_local` instant paint;
live `updateNewMessage`; gap handling; composer (Enter send / Shift+Enter newline) with the
focus ordering from §3.3 and `EditShortcutMonitor` installed; optimistic send with `sending_id`
correlation and failed-send retry; read ticks from `last_read_outbox_message_id`;
`viewMessages(force_read: true)`; date separators; scroll anchoring
(`.defaultScrollAnchor(.bottom)` + preserved position on backward pagination).
Bubbles per P3. Gate: L1–L3.

### M7 — Media (T1 view + T2 send)
Inline photos (minithumbnail → chosen `photoSize` by width × backingScale); webp stickers natively,
`thumbnail` fallback for tgs/webm; GIFs branched on `mime_type` (mp4 → looping muted AVPlayer);
voice via **`AVAudioPlayer`**; video as thumbnail + duration opening externally.
Sending: drag-drop (port boring.notch's `DragDetector` — global mouse monitors +
`NSPasteboard(name: .drag).changeCount` to force-expand, because `ignoresMouseEvents = true` while
collapsed makes `.onDrop` dead), **paste strictly as ⌘V / `.onPasteCommand` inside the focused
composer** (never poll `generalPasteboard.changeCount` — macOS 26 Paste Protection would put
NotchGram in the "Paste from Other Apps" privacy pane and a Deny breaks image paste permanently),
attach button. Reply-to; context menu (copy / edit own / delete for me / for all) gated on
`messageProperties`, with the pin set from the action that *presents* the menu (menu tracking runs
a nested runloop that the hover poll ignores — the panel would otherwise collapse out from under
an open menu). Gate: L1–L3.

### M8 — Search, profile, settings (T1)
`searchChats` on each keystroke + debounced `searchChatsOnServer` (~300 ms) merged; open result.
Self profile. Settings: panel size (presets + custom, clamped per §3.5, applied via `rebuild()`),
collapsed unread-badge toggle (D10, default off, fed by `updateUnreadChatCount`), launch at login
(exercise **only** against the `/Applications` copy — registration binds to the app's path),
logout. Gate: L1–L3.

### M9 — T2 remainder
Typing indicators (`sendChatAction` re-sent ~5 s; incoming via `updateChatAction`); chat folders as
tabs (`updateChatFolders`, `chatListMain` inserted at `main_chat_list_position`); basic
notifications (pragmatic path, mute resolved through the `use_default_*` flags + scope settings,
suppressed for `is_outgoing`, de-duplicated by `(chat_id, message_id)` across launches, cleared on
`updateChatReadInbox`; clicking a banner routes back into the panel via the UN delegate). If
running long, move items to the stretch loop rather than slipping the release. Gate: L1–L3.

### M10 — Real-account verification + release  *(requires CP1)*
L4 probe; perf sanity (cold start < 2 s to expanded panel, smooth chat-list scroll, idle RAM
~400 MB — investigate anomalies, don't gate on exact numbers; also watch the AsyncStream buffer
depth during first sync); fix what the probe surfaces; acceptance checklist with evidence;
`session-01-report.md`; update ROADMAP / ARCHITECTURE / the session-02 brief; merge to `main`,
tag `v0.1.0`, `make install` (Release / Developer ID). Gate: L1–L4 → **CP2**.

`.artifacts/` will contain the founder's real chats from CP1 onward: it stays gitignored, and no
real chat content goes into the report or commit messages.

### M11+ — Stretch loop
Deferred M9 items first, then T3 order: voice recording, reactions (view → set), forwarding,
animated TGS stickers, link previews, mute controls, archived chats. One item at a time, fully
verified, committed, merged.

---

## 6. Verification harness

- **L1 unit** — `make test` → `.artifacts/test.xcresult` →
  `xcrun xcresulttool get test-results summary --compact`. Pure targets: `NotchGeometryEngine`
  over `FixtureScreenProvider`, `AuthFlow`, `ChatRepo.applyPositions`, `SendPipeline` temp→real
  remap, `FullScreenProbe` over fabricated window listings.
- **L2 integration** — `make itest` against the test DC, fresh account per run, JSON report to
  `.artifacts/itest.json`.
- **L3 UI smoke** — `make run` (with captured stdout/stderr) → DebugBridge `POST /command`
  (returns post-transition state, so no racing the 450 ms spring) → `screencapture -x -o -l
  <windowNumber>` **plus** the in-app `ImageRenderer` capture as the TCC-free fallback → agent
  reviews the images. One `CGWarpMouseCursorPosition` pointer-level hover smoke per UI milestone.
- **L4 real account** — after CP1 only, per the brief.
- Evidence to `.artifacts/`, referenced from the session report.

---

## 7. Deltas — what this plan changes in the committed docs

Applied in **M-1**, before any code, so the repo and the plan don't diverge. Each amendment cites
`docs/sessions/session-01-plan.md` (this document) as the source of the resolved facts:

**ARCHITECTURE.md**
- Correct the "Known signing/TCC facts" note: **two** identities exist (Apple Development +
  Developer ID Application); signing is profile-free; don't pass `-allowProvisioningUpdates`.
- `NotchShell` is **one panel per screen** with shared state, not a singular `NotchWindow`.
- `HoverTracker` is a **poll loop**, not a tracking area / global monitor.
- `AuthFlow` covers **13** authorization states, not 5.
- Amend **D11**: Debug = Apple Development, Release/`make install` = Developer ID; one identity
  per `/Applications` bundle, permanently.
- New decisions: **D14** synthetic notch at half a real notch's width, MVP scope (P2) ·
  **D15** per-screen panels + single expanded host · **D16** polled hover · **D17** non-activating
  panel + `canBecomeKey`, never `NSApp.activate()` · **D18** DebugBridge = loopback HTTP, shipped in Release but inert unless enabled ·
  **D19** ITest as a `tool` target (viable because the xcframework is static) · **D20** signing
  split above · **D21** pragmatic notifications for MVP, real `updateNotificationGroup` path in
  Session 2 · **D22** panel stays summonable over fullscreen (alpha 0, not `orderOut`) ·
  **D23** Sendable strategy (retroactive conformances + scoped `@preconcurrency`).

**session-01-mvp.md**
- M0 gains gates G1–G4 (§5).
- M3 gains synthetic notch + multi-display + the geometry testability seam.
- Acceptance checklist: "Panel appears over a fullscreen app's Space" → "Panel can be **summoned**
  over a fullscreen app's Space" (D22).
- Add: notification authorization is requested in M0 so CP1's ping cannot silently fail.
- Add the "never `pkill`, always quit via DebugBridge" rule (TDLib SQLite integrity).

**CLAUDE.md** — inherit Dictate's hard-won rules: `project.yml` is the source of truth (never edit
the `.xcodeproj`); bundle id + team are frozen; build only via `make`; anything leaving this Mac is
Developer ID + notarized; targeted `nonisolated(unsafe)` with a stated invariant is fine, blanket
`@unchecked Sendable` is not; **TDLibKit API questions are answered from the pinned tag's sources,
not from tutorials** (`TdClientImpl` is deprecated, `sendMessage` gained `topicId`,
`inputMessagePhoto` nests `InputPhoto`, `updateUserChatAction` no longer exists).

---

## 8. Risks and fallbacks

| Risk | Fallback |
| --- | --- |
| TDLibFramework fails to link/sign under Xcode 26.6 (CI only covers 16.4) | Caught at M0 G2 before anything is built on it. Inspect the bundle's `Versions/Current` symlink first. Emergency exit: `libtdjson` bridge — budget 1–3 days, not hours. |
| 343 MB resolve fails or stalls | `make deps` is separate and started first; on failure `rm -rf ~/Library/Caches/org.swift.swiftpm/artifacts` and retry; pin by `revision:` if the prerelease string misbehaves. |
| **M0 G3 fails** — the TextField doesn't take keystrokes inside the real signed bundle (it worked in a standalone probe, but the bundle adds hardened runtime + Developer ID + LSUIElement) | Drop `.nonactivatingPanel` from the styleMask (keep `.borderless`) and accept that expanding **activates** NotchGram. That invalidates the "hover never steals focus" UX claim, so re-examine the interaction model **before M6** rather than after six milestones sit on it: likely hover→expand stays passive via `ignoresMouseEvents`, and only a click activates. Ladder if needed: `NSApplication.activate()` (macOS 14+; `activateIgnoringOtherApps:` is soft-deprecated in the 26 SDK) → `NSRunningApplication.activate(from:options:)` → `NSApp.yieldActivation(to:)` on release. |
| Test DC flooded / down | Randomized YYYY + fresh db per run makes it structurally unlikely; otherwise mocked transport now, live checks deferred to M10, noted in the report. |
| Swift 6 diagnostics eat M1 | Strategy pre-decided (§3.6); budget it as a known 30–60 min task, not a discovery. |
| Panel/menu-bar interaction at 880 pt | Decided in M3 (hit-region carve-out); the level is DebugBridge-settable so `.statusBar + N` is a one-command experiment. |
| Clamshell / hot-unplug untestable unattended | Covered by geometry fixtures 3, 4 and 10; the physical transition is a CP2 human check. |
| Session running long | Tier discipline: T1 fully, then T2; anything unfinished in M9 moves to the M11 stretch loop rather than slipping `v0.1.0`. |

---

## 9. Authorization this plan assumes

Approving this plan authorizes the build session to, **on a green acceptance checklist and without
further confirmation**: merge `session-01-mvp` into `main`, push to `origin/main`, tag `v0.1.0`,
and install to `/Applications` (P1). Everything else stays inside the session branch, which lives
in a `/mkwt` worktree rather than the main checkout.

Founder touches remain three: **CP0** launch · **CP1** one ~2-minute in-panel Telegram login after
M4 · **CP2** final acceptance after M10. The two permission grants that could have become a fourth
(Screen Recording, Accessibility) are already in place, and the notification grant is requested in
M0 so CP1's ping cannot silently fail.
