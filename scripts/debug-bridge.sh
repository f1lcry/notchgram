#!/usr/bin/env bash
# Thin client for the DebugBridge control channel (D18).
#
#   scripts/debug-bridge.sh status
#   scripts/debug-bridge.sh cmd '{"command":"expand"}'
#   scripts/debug-bridge.sh socket
#
# The transport is HTTP over a **Unix domain socket**, not loopback TCP: macOS
# gates local-network access per application, and the Developer ID Release build
# in /Applications never received TCP connections with nobody at the keyboard to
# approve it. A Unix socket is not networking, so there is nothing to approve.
#
# A command response carries the POST-TRANSITION state, so callers never race
# the ~450 ms unfold spring.
set -euo pipefail

APP_NAME="NotchGram"
SOCKET="$HOME/Library/Application Support/$APP_NAME/debug.sock"

require_socket() {
  [ -S "$SOCKET" ] || {
    echo "debug-bridge: no socket at $SOCKET — app not running, or bridge disabled" >&2
    exit 2
  }
}

case "${1:-status}" in
  socket)
    echo "$SOCKET"
    ;;
  status)
    require_socket
    curl -sS -m 10 --unix-socket "$SOCKET" http://localhost/status
    ;;
  health)
    require_socket
    curl -sS -m 5 --unix-socket "$SOCKET" http://localhost/health
    ;;
  cmd)
    [ $# -ge 2 ] || { echo "usage: $0 cmd '<json>'" >&2; exit 64; }
    require_socket
    curl -sS -m 30 --unix-socket "$SOCKET" -X POST http://localhost/command \
      -H 'Content-Type: application/json' -d "$2"
    ;;
  *)
    echo "usage: $0 {status|health|socket|cmd '<json>'}" >&2
    exit 64
    ;;
esac
