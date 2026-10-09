# Session 7 — Obsidian redesign (report)

Date: 2026-08-26. Branch: `session-07-redesign`. Founder-commissioned
interactively (no written brief): drop the Telegram-Desktop blue clone —
the blue slab made the physical notch read as a hole in the app — and give
NotchGram its own skin that merges with the notch, with Liquid Glass
accents and Apple-grade motion.

## Direction: "Obsidian"

The panel *is* the notch. One material — black glass — flowing out of the
hardware cut-out with no visible seam.

- **Ground**: pure black everywhere (`panelShell`, `background`). The
  hardware boundary disappears; the top strip and gutters are the same
  material as the cut-out.
- **Structure**: whisper-quiet white elevation steps (2% → 5% → 6% → 11%)
  plus `hairline` edge-light strokes. Never a hue shift.
- **Color**: exactly one accent — ice cyan `0x64D2FF` (Apple's dark-mode
  cyan, deliberately not Telegram blue) — spent only on meaning: unread,
  send, focus, read ticks, typing. Badge text is ink-on-ice, not white.
- **Bubbles as glass**: incoming graphite (`white 7.5%` + hairline),
  outgoing ice (`accent 16%` + accent hairline). Read by material, not by
  loud fill.
- **Liquid Glass, two tiers** (`Glass.swift`): the real macOS 26
  `glassEffect` only where an element floats over content (scroll-to-bottom
  FAB, media-viewer chrome); painted glass (`insetGlass`) for structural
  surfaces — deterministic on flat black and cheaper than live refraction
  nobody can see there.
- **Motion vocabulary** (`Theme.Motion`): quick 0.14s ease-out for hovers
  and focus; springs for pane swaps, the sliding folder-tab pill
  (`matchedGeometryEffect`), the send button arming pop; `numericText`
  content transitions on unread counters; staggered typing dots. Nothing
  travels sideways inside the slab; transform/opacity only.

## What changed

- `Theme.swift` — full token rewrite + `Motion`; bubble radius 14→15/5→6.
- `Glass.swift` (new) — `glassIsland`, `insetGlass`, `PressableButtonStyle`,
  `PanelIconButton`, `TypingDotsView`. `GlassBackdrop.swift` (dead since the
  opaque-slab decision) removed.
- Chat list: headerless header (search glass carries it), sliding glass
  pill on folder tabs, glass selection pill + hairline on rows, ice badges.
- Conversation: glass bubbles with rim light, glass day chips, restyled
  unread strip, Liquid Glass FAB, typing dots in the header.
- Composer: `insetGlass` field with accent focus ring, `PanelIconButton`
  attach, ink-on-ice send disc that arms with a pop.
- Auth: primary = solid ice + ink, secondary/fields = painted glass.
- Settings/Profile: chips with hairlines + accent-tinted selection, accent
  toggles, shared icon buttons.
- Pane switches breathe (fade + 0.985 scale) instead of blinking.

## Verification

`make build` clean; 109/109 unit tests green. Live screenshots over
DebugBridge fixtures (`chatList`, `conversation` — note the bridge arg is
`state`, not `name`) and — unplanned — over the founder's real account
mid-session: bubbles, unread divider, focus ring and day chips all render
as designed on real data. Screens in `.artifacts/redesign-*.png` (kept locally, not published).

## Debt / notes

- Fixture injections landed in the founder's live session; a relaunch
  clears the in-memory fixture chats.
- Auth screens restyled but not visually screenshotted this session
  (token-level change; states remain reachable via `gotoAuthState`).
- The media viewer's Liquid Glass chrome is unverified against a real
  photo backdrop.
- `VoiceNote`/album scrims kept black-on-media (correct over pixels).
