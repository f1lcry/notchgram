#!/usr/bin/env bash
# Graceful shutdown of NotchGram (D20).
#
# NEVER SIGKILL this app. TDLib holds an encrypted SQLite database open; a hard
# kill risks corrupting it, and a corrupt database after CP1 costs the founder a
# re-login — i.e. burns a founder checkpoint.
#
# Order: DebugBridge `quit` (in-process NSApp.terminate) → osascript → SIGTERM.
# osascript is second because it can raise a one-time Automation TCC dialog.
set -uo pipefail

BUNDLE_ID="com.f1lcry.notchgram"
APP_NAME="NotchGram"
SOCKET="$HOME/Library/Application Support/$APP_NAME/debug.sock"

running() { pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; }

wait_for_exit() {
  local deadline=$(( SECONDS + $1 ))
  while running; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.25
  done
  return 0
}

if ! running; then
  echo "quit: not running"
  exit 0
fi

# 1. DebugBridge
if [ -S "$SOCKET" ]; then
  curl -sS -m 5 --unix-socket "$SOCKET" -X POST http://localhost/command \
    -H 'Content-Type: application/json' \
    -d '{"command":"quit"}' >/dev/null 2>&1 || true
  if wait_for_exit 10; then echo "quit: via DebugBridge"; exit 0; fi
fi

# 2. AppleScript
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
if wait_for_exit 10; then echo "quit: via osascript"; exit 0; fi

# 3. SIGTERM — still a clean shutdown path for AppKit, unlike SIGKILL.
pkill -TERM -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
if wait_for_exit 15; then echo "quit: via SIGTERM"; exit 0; fi

echo "quit: FAILED — $APP_NAME still running. Do NOT kill -9 (TDLib SQLite)." >&2
exit 1
