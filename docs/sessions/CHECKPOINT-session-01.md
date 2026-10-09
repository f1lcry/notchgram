# NotchGram — what needs you

Session 1 built T1 and T2. Everything verifiable without a Telegram account has
been verified live; the rest is written and waiting on you. Full write-up:
`docs/sessions/session-01-report.md`.

Three things, in order. The first takes ~2 minutes; the rest we can do together.

---

## 1. Sign in (this is CP1)

NotchGram is already installed at `/Applications/NotchGram.app` — Developer ID
signed, notarized and stapled. It should be running; if not, open it.

- Hover the notch. The panel expands and shows **Sign in to Telegram**.
- Phone → code → 2FA.
- If the panel refuses for any reason: `make login` in the repo is the CLI
  fallback.

Why it matters more than planned: Telegram's **test data centre no longer
accepts its own documented login code** (reproduced here against DC 1 and DC 2,
and open as [tdlib/td#3083](https://github.com/tdlib/td/issues/3083) since 2021
for everyone including Telegram's own `tg_cli`). That was supposed to give
automated coverage of chats, sending and media without you. It cannot, so your
account is now the only route to that.

Nothing you do here is risky: the app has run against the real DCs all session
in the signed-out state, quits gracefully, and the TDLib database is intact.

---

## 2. Allow notifications

**System Settings → Notifications → NotchGram → Allow Notifications.**

`UNUserNotificationCenter.authorizationStatus` currently reports `.denied` for
`com.f1lcry.notchgram`, which means the app can never ask again — macOS requires
you to flip it. Until then no banner can be delivered and the notification path
(built, D21) cannot be verified.

Verified it is not a code problem: only `/Applications` is registered with
LaunchServices, the app is Developer ID signed, the delegate is set before the
request, and the request is made after the run loop is up.

---

## 3. Reconnect the external displays

This is the **largest untested surface in the session**. Only the built-in
display was attached tonight, so the multi-display behaviour is verified by unit
fixtures only — and P2 says external displays are your daily case.

Once they are plugged in:

```sh
# from the repo checkout
# one panel per screen, with its own geometry
scripts/debug-bridge.sh status | jq '.screens, .panels[] | {screenUUID, isPhysicalNotch, notchRect, panelSize, state}'

# hover each screen's tab in turn — only one panel should ever be expanded
scripts/debug-bridge.sh status | jq '[.panels[] | select(.state != "collapsed")] | length'
```

Then two things a script cannot do:

- **Unplug a monitor while the panel is open.** It should rebuild once, not
  flash three to five times (there is a 220 ms debounce for exactly this).
- **Close the lid** with an external attached. The built-in disappears from
  `NSScreen.screens` entirely; the remaining screens should each keep a drawn
  tab.

---

## After that — M10, together

The acceptance checklist for `v0.1.0`, on your real data: chat list with correct
unread counts, scroll back 200+ messages in a busy group, text round trip to
your phone, photo in and out (drag-drop **and** paste), sticker/GIF/voice,
search, panel size persistence, summoning over a fullscreen Space, and
launch-at-login across a reboot. Then `make release` — notarized DMG plus the
`/Applications` install — and the `v0.1.0` tag.

Two things I deliberately did **not** build, both moved to Session 2 because
they are worthless unverified: reply-to with the edit/delete context menu, and
drag-and-drop onto the *collapsed* notch (dropping onto the expanded panel
works).

---

## When we're done — turn the bridge off

`DebugBridgeEnabled` is currently `YES` on this machine so I can drive the panel
for the M10 checks. D18 says it is off for daily use, so once `v0.1.0` is
tagged:

```sh
defaults delete com.f1lcry.notchgram DebugBridgeEnabled
scripts/quit-app.sh && open -a NotchGram
```

Nothing else was left behind: panel size is back to 880×580 and the synthetic
notch override is off (`defaults read com.f1lcry.notchgram` to confirm).

---

## Handy commands

```sh
make run                      # Debug build, logs to .artifacts/run.{out,err}.log
make install                  # Developer ID Release → /Applications
make release                  # notarized DMG + install
scripts/quit-app.sh           # graceful quit — never kill -9, TDLib holds SQLite
scripts/debug-bridge.sh status
scripts/capture-auth-states.sh   # screenshots all 17 login screens
```
