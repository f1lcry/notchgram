# Session 1 — report

Branch `session-01-mvp`, 2026-08-23. Contract:
[session-01-mvp.md](session-01-mvp.md) · implementation layer:
[session-01-plan.md](session-01-plan.md).

**Status: T1 and T2 are built; the release is blocked on CP1.** Everything that
could be verified without a Telegram account has been, live, with evidence in
`.artifacts/` (kept locally, not published). Everything that needs real chat data is written and unverified,
because the automated route to it — the Telegram test DC — turned out not to
work. That is the one thing that changed the shape of the session, and it is why
`v0.1.0` is not tagged.

The founder's remaining work is three items, listed in
[CHECKPOINT-session-01.md](CHECKPOINT-session-01.md) (also copied to
`.artifacts/CHECKPOINT.md`) and repeated at the
end of this file.

---

## What shipped

11 441 lines across 73 Swift files, one commit per milestone on
`session-01-mvp`, `make test` green at **97/97**, `make itest` green in ~7 s.

| Milestone | State |
| --- | --- |
| M0 scaffold + gates G1–G4 | done, all four gates green, fresh-clone path proven |
| M1 TelegramCore | done, live against the real Telegram DCs |
| M2 test-DC integration | **redefined** — see below |
| M3 NotchShell | done; multi-display verified by fixtures only |
| M4 auth UI | done, all 13 states, screenshotted |
| M5 chat list | done, fixture-verified |
| M6 conversation | done, fixture-verified |
| M7 media viewing | done, fixture-verified |
| M7 media sending | built, **unverified** (needs an account) |
| M8 search / profile / settings | done; launch-at-login verified for real |
| M9 typing / folders / notifications | built; notifications **unverified** |
| M10 real-account probe + release | **blocked on CP1** |
| Notarization (added at CP0) | done and verified end to end |

---

## The thing that changed the session: Telegram's test DC does not work

The brief's whole autonomy story rested on the test DC: reserved numbers
`99966XYYYY` with a fixed code, so an agent can log in, send, receive and
download media with no founder involvement.

**It is broken server-side.** Measured here, in TDLib's own request log:

```
setAuthenticationPhoneNumber { phone_number = "9996618856" }
  -> authorizationStateWaitCode { code_info = { type = authenticationCodeTypeSms { length = 5 } } }
checkAuthenticationCode { code = "11111" }
  -> error { code = 400 message = "PHONE_CODE_INVALID" }
```

That is exactly the documented contract, and exactly the maintainer's own answer
in [tdlib/td#1524](https://github.com/tdlib/td/issues/1524) ("read the length
from `codeInfo`"). The 6- and 4-digit variants were rejected too, on DC 1 and
DC 2. It is not specific to NotchGram:
[tdlib/td#3083](https://github.com/tdlib/td/issues/3083) has the identical
failure for Telegram's own `tg_cli` with the sample api_id, open since 2021,
with a maintainer of another major client saying he gave up and runs real
accounts against the test server instead.

**Consequences, all recorded as decisions D29/D30:**

- `make itest` was redefined rather than left permanently red. It reports three
  sections: `liveAuthProbe` **passes** (cold start → 14-field
  `setTdlibParameters` → phone → `waitCode`, which exercises the singleton
  manager, the ordered update stream, the Keychain-free key path, deadlines, DC
  failover and code-length derivation); `liveRoundTrip` is **skipped with the
  reason and the issue link**, retryable with `--live-roundtrip` the day
  Telegram fixes it; `updateReplay` points at L1. A gate that can never go green
  is a gate everyone learns to ignore.
- Only the **inbound** direction is mocked. `UpdateFixtures` synthesizes
  `Update` values and the repos' `apply(Update)` paths are replayed offline —
  that is where the ordering and send-correlation bugs actually live. The
  outbound direction is deliberately *not* faked: a round trip asserting "the
  text I sent is in the history" against a fake that put it there proves
  nothing. That assertion belongs to L4, on the real account.
- The same fixtures drive `DebugBridge injectFixture`, which is how the chat
  list, conversation and media views were built and screenshotted with no
  account at all.
- **CP1 became load-bearing.** It was designed as a non-blocking convenience;
  it is now the only route to live chat data, and therefore the gate on M10.

Also learned: **test DC 3 is unreachable from this network** (`Timeout expired …
to DcId{3}`, `No route to host` over IPv6) while DC 1 and 2 answer in about a
second. The harness fails over across DCs and remembers the last good one in
`.artifacts/itest/preferred-dc` rather than encoding one network's blocklist.

---

## Bugs found by measurement, not by reasoning

These are the ones worth remembering; each cost real time and none would have
been caught by reading the code.

**The Release build was completely frozen, and only the DebugBridge showed it.**
`sample` gave the answer in one line: main thread in
`TelegramSession.sendParameters → KeychainStore.read → SecItemCopyMatching →
mach_msg`, blocked forever. `SecItemCopyMatching` is synchronous IPC to
`securityd`, and `securityd` was waiting for a confirmation dialog nobody was
there to answer. The panel was dead too. Two fixes: Keychain access is now async
and off the main actor, and items are created with an ACL that trusts any
application — because an item added without an explicit `kSecAttrAccess` binds
to **one code signature**, and D11 mandates two (Apple Development for Debug,
Developer ID for `/Applications`). The second build to run always got prompted.
The trade is deliberate and small: the secret is a local database key sitting
beside the database it encrypts, under the same user's permissions.

**`.terminateLater` deadlocks Swift Concurrency.** It parks AppKit in a nested
wait loop that does not service the main-actor executor: the shutdown task and
its watchdog both never ran a single line, and the process was still alive 25 s
after `quit`. A hung quit pushes the operator toward `kill -9`, which is the
database corruption D20 exists to prevent. Replaced with `.terminateCancel` plus
a re-issued `NSApp.terminate`; quit is now 0.34 s (D27).

**`await client.close()` can hang forever.** TDLibKit's manager routes a
response by looking the client up in `clients` *after* removing it on
`authorizationStateClosed`. When TDLib emits the closed state before the `Ok`,
the completion is dropped and the continuation is never resumed. Use the
completion form; wait on the closed state with a deadline (D28).

**A TDLib request to an unreachable data centre never answers and never errors**
— and TDLibKit's `withCheckedThrowingContinuation` cannot be cancelled, so the
`await` hangs. Unbounded, the panel would spin forever with nothing to show.
Every request now goes through `withDeadline` (D26).

**The DebugBridge needed two rewrites.** `NWListener(on: .any)` binds `*:port`
on IPv6 even with `requiredInterfaceType = .loopback`, and macOS gates
local-network access per application: the `/Applications` Release build
completed the TCP handshake and then never received the request, unattended,
with nothing to approve it. Moved to HTTP over a **Unix domain socket** — not
networking, so no firewall and no prompt. The first cut of that had its own bug
(a blocking listening socket, where the accept loop's second call parked the
main queue), and a `DispatchSource` read source on the listener silently stopped
delivering connections after a while. It is now a blocking `accept` on a
dedicated thread with per-connection tasks, `SIGPIPE` ignored, and it survived
14 consecutive commands including two panel rebuilds.

**Messages arriving in the open chat were never marked read** — the badge would
never have cleared with the founder watching. Read receipts now follow panel
`settled`, not merely `expanded`: `forceRead` tells Telegram the messages were
seen, and a hover brushing past an open chat should not claim that.

**`ChatRepo` was O(chats²) during first sync**, which is exactly when cold-start
time gets measured. Now per-chat cached, invalidated only where touched, and
identical arrays are not reassigned.

---

## Deltas from the plan

| Change | Why |
| --- | --- |
| `Secrets.generated.swift` moved to `Sources/TelegramCore/` | The ITest `tool` target compiles TelegramCore and nothing from `Sources/App`, so the harness could not see the credentials. |
| Notarization pulled into Session 1 (D24) | Founder added it at CP0. Verified end to end: submission `27feb2af…` Accepted, stapled, `spctl` reports `source=Notarized Developer ID`. |
| `make itest` redefined (D29) | See above. |
| Only the inbound direction is mocked (D30) | See above. |
| Every TDLib request bounded (D26) | See above. |
| `.terminateCancel` instead of `.terminateLater` (D27) | See above. |
| Completion-form `close` (D28) | See above. |
| DebugBridge on a Unix socket, not loopback TCP | See above. Amends D18's transport; the reasoning for HTTP is unchanged. |
| Reply-to and the edit/delete context menu not built | M7's T2 remainder. They need a signed-in account to be worth anything, and the session ran out of verifiable work before it ran out of buildable work. Moved to Session 2. |
| Drag-and-drop onto the **collapsed** notch not built | `ignoresMouseEvents` is true while collapsed, so `.onDrop` is dead there; the plan's `DragDetector` (global monitors + `NSPasteboard(.drag).changeCount`) is the fix and is Session 2. Dropping onto the expanded panel works. |

### Swift 6 friction, as promised in the brief

23 `@preconcurrency import TDLibKit` (one per file touching the package, plus
one `@preconcurrency` conformance for `UNUserNotificationCenterDelegate`, whose
parameters are non-Sendable ObjC classes). Two `nonisolated(unsafe)` spots, both
with a stated invariant: `TDLibRuntime.manager` and `TDClient.client`. One file
of retroactive `@unchecked Sendable` conformances (`TDLibKit+Sendable.swift`) —
every type in it is a struct or an indirect enum with value-only payloads.
`TDLibKit.Error` is deliberately absent: the compiler already infers Sendable
for it.

---

## Verification

| Layer | State |
| --- | --- |
| L1 unit | **97/97**, `.artifacts/test.xcresult` |
| L2 integration | live auth probe **passes**; live round trip **skipped with cause**; update replay in L1 — `.artifacts/itest.json` |
| L3 UI smoke | 33 screenshots in `.artifacts/`, incl. all 17 auth screens; real pointer hover verified; every state driven through DebugBridge |
| L4 real account | **not run — CP1** |

Things verified *live*, not by fixture:

- TDLib 1.8.66 links, signs and runs from the signed bundle; the real account
  reaches `waitPhoneNumber` with `connectionState: ready`.
- Hovering the physical notch expands the panel and moving away collapses it,
  with `NSWorkspace.frontmostApplication` unchanged (D17 holds inside the real
  bundle).
- `forceSynthetic` produces a 93×16 tab — half the built-in's 185-wide cut-out,
  as D14 requires.
- Panel resize rebuilds to 1040×680 and back.
- Notarization, stapling and `spctl` acceptance.
- Launch at login on the `/Applications` Developer ID build.
- Graceful quit with the TDLib database intact.

Things **not** verified, and honest about it: everything involving real chats —
the chat list against real data, send/receive round trip, media upload and
download, search, notifications, and the multi-display behaviour (only the
built-in display was attached; the externals were elsewhere).

---

## Founder actions

1. **Sign in.** Open NotchGram (it is in `/Applications`), hover the notch,
   enter phone → code → 2FA. `make login` is the CLI fallback if the panel
   blocks.
2. **System Settings → Notifications → NotchGram → Allow Notifications.**
   `authorizationStatus` is currently `.denied`, so no banner can be delivered
   and M9 cannot be verified. This is a system setting, not a code fix.
3. **Reconnect the external displays**, then run the multi-display checks in
   `.artifacts/CHECKPOINT.md`. This is the largest untested surface in the
   session and P2 says external displays are the daily case.

Then M10: the L4 probe, the acceptance checklist, `v0.1.0`, `make release`.
