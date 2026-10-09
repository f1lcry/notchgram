#!/usr/bin/env bash
# Captures the NotchGram panel into .artifacts/.
#
# Primary path: `screencapture -l <windowNumber>` with the window id read from
# DebugBridge /status. Fallback: the in-app ImageRenderer capture over
# DebugBridge, which needs no Screen Recording grant and works even when the
# panel is occluded.
#
#   scripts/screenshot.sh [name]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
name="${1:-panel}"
stamp="$(date +%Y%m%d-%H%M%S)"
out="$repo_root/.artifacts/${name}-${stamp}.png"
mkdir -p "$repo_root/.artifacts"

status="$("$here/debug-bridge.sh" status)" || {
  echo "screenshot: DebugBridge unreachable — is the app running (make run)?" >&2
  exit 1
}

wid="$(printf '%s' "$status" | jq -r '.windowNumber // empty')"

if [ -n "$wid" ] && [ "$wid" != "null" ] && [ "$wid" != "0" ]; then
  screencapture -x -o -l "$wid" "$out" 2>/dev/null || true
fi

if [ ! -s "$out" ]; then
  echo "screenshot: window capture empty — falling back to in-app ImageRenderer" >&2
  rm -f "$out"
  "$here/debug-bridge.sh" cmd "{\"command\":\"screenshot\",\"path\":\"$out\"}" >/dev/null
fi

test -s "$out" || { echo "screenshot: produced no bytes at $out" >&2; exit 1; }
echo "$out"
