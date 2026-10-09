# NotchGram

macOS notch-anchored Telegram client: hover the notch → a
Telegram-Desktop-sized panel expands. Standalone TDLib client (direct
MTProto, no backend of ours). Swift 6, AppKit shell + SwiftUI content,
XcodeGen. Open source (GPL-3.0-or-later); unofficial client, not affiliated
with Telegram.

## Session start

1. Run `scripts/preflight.sh`.
2. Read `docs/ROADMAP.md`, then the active brief in `docs/sessions/`, then its
   implementation plan (`session-NN-plan.md`) — the plan holds the already-
   verified facts the brief leaves open; do not re-derive them.
3. Build sessions follow the brief's milestone + verification contract;
   the brief also defines what is pre-authorized (e.g. merging to `main`).

## Commands

- `make deps` — resolve SPM packages (TDLibFramework is a ~343 MB download)
- `make build` / `make run` — xcodegen + xcodebuild, launch the app
- `make test` — unit tests · `make itest` — headless test-DC integration
- `make login` — interactive real-account CLI login (founder-run fallback;
  primary real login happens in the panel UI)
- `make install` — Release build → /Applications
- `make screenshot` — capture the panel window into `.artifacts/`
- `make release-build` + `make verify-release` — Release build, then the gate
  that fails if DebugBridge, CheckpointNotifier or demo-mode markers reached the
  binary, or Sparkle keys / third-party notices are missing (D43)
- `make release VERSION=x.y.z [DRY_RUN=1]` — the maintainer's publish path
  (`scripts/release.sh`): notarized DMG, GitHub release, appcast feed, tap
- `make media` — regenerate `docs/media/` from `NOTCHGRAM_DEMO=1` (D45)

## Secrets

- `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` live in `.env` (gitignored);
  committed contract in `.env.example`. Every builder registers their own
  app at my.telegram.org.
- Never hardcode or log them. The only consumption path is
  `scripts/gen-secrets.sh` → `Secrets.generated.swift` (gitignored).

## Signing / TCC (learned in Dictate — do not rediscover)

- Automatic signing with the team from `Config/Signing.xcconfig`; contributors
  build under their own team by copying `Config/Local.xcconfig.example` to
  `Config/Local.xcconfig` (untracked), never by editing `project.yml`. Release
  signing (Developer ID + notarization) is the maintainer's `make release` path.
- Bundle id `com.f1lcry.notchgram` is frozen (TCC identity).

## Hard-won rules (do not rediscover)

- `project.yml` is the source of truth; the `.xcodeproj` is generated
  (`make generate`) and gitignored. **Never edit the xcodeproj.**
- Build and install only through `make`. Anything that leaves this Mac goes
  through the Developer ID + notarize path; the Apple Development build is
  flagged as malware by Gatekeeper elsewhere.
- **Never `pkill`/SIGKILL the app** — TDLib holds an encrypted SQLite open.
  Quit via DebugBridge → `osascript` → `-TERM` after a timeout (D20).
- **TDLibKit questions are answered from the pinned tag's own sources**
  (`github.com/Swiftgram/TDLibKit`), never from tutorials. Known stale advice:
  `TdClientImpl` is deprecated (use `TDLibClientManager`), `sendMessage` gained
  a `topicId` parameter, `inputMessagePhoto` now nests an `InputPhoto`,
  `updateUserChatAction` no longer exists (it is `updateChatAction`), and
  `TDLibClientManager.closeClients()` busy-waits — never call it on a
  termination path.
- Notch-engine invariants ported from Dictate: hover is **polled**, never a
  tracking area; hit-test the inflated `trigger` rect because `NSRect.contains`
  excludes the max edge; the panel window **never changes frame** (a size
  change is a rebuild while collapsed); `canJoinAllSpaces` decays, repair with
  `orderOut` then `orderFrontRegardless`; content must be `.clipShape`d to the
  slab.
- Swift 6: fix diagnostics properly. Targeted `nonisolated(unsafe)` with a
  stated invariant is fine; blanket `@unchecked Sendable` is not (the
  sanctioned exception is `TDLibKit+Sendable.swift`, D23).

## Conventions

- English everywhere in the repo (code, comments, commits, docs).
  Conventional commits. Swift 6 strict concurrency; `@preconcurrency` only
  when a dependency forces it.
- Session branches `session-NN-*`; merge to `main` only per an active
  brief's authorization (acceptance checklist green). Releases tagged
  `vX.Y.Z`.
- Test artifacts and screenshots → `.artifacts/` (gitignored).
- Anything automated targets the Telegram **test DC** (accounts in
  `AccountRegistry` marked `useTestDc`; reserved numbers `99966DXXXX`,
  fixed codes — verify the exact contract in TDLib docs). The real account
  is touched only at founder checkpoints or after CP1 per the active brief.
- Docs are living: every session ends by updating ROADMAP / ARCHITECTURE
  and writing its `docs/sessions/session-NN-report.md`.
- Key architectural invariants: singleton `TDLibClientManager` (one
  `td_receive` thread) with one client id per account; every UI state
  reachable through DebugBridge, never only via physical hover.
