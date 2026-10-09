#!/usr/bin/env bash
# NotchGram preflight — validate the machine before an autonomous build session.
#
# The TCC grants below belong to the *calling* process (this terminal), not to
# NotchGram: `screencapture` and `CGEventPost` are gated on the caller. Without
# them the L3 UI-smoke layer silently degrades, so they are hard failures.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok()   { printf '  ok   %s\n' "$1"; }
warn() { printf '  WARN %s\n' "$1"; }
err()  { printf '  FAIL %s\n' "$1"; fail=1; }

echo "== NotchGram preflight =="

macos_ver="$(sw_vers -productVersion 2>/dev/null)" \
  && ok "macOS $macos_ver" || err "sw_vers failed — not macOS?"

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode developer dir: $(xcode-select -p)"
else
  err "Xcode command line tools missing (xcode-select --install)"
fi

if command -v swift >/dev/null 2>&1; then
  ok "$(swift --version 2>/dev/null | head -1)"
else
  err "swift not found"
fi

if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version 2>/dev/null)"
else
  err "xcodegen missing — brew install xcodegen"
fi

if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>/dev/null)"
else
  err "jq missing — brew install jq (DebugBridge harness parses JSON with it)"
fi

# .env contract
if [ -f "$repo_root/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$repo_root/.env"; set +a
  if [ -n "${TELEGRAM_API_ID:-}" ] && [ -n "${TELEGRAM_API_HASH:-}" ]; then
    ok ".env: TELEGRAM_API_ID / TELEGRAM_API_HASH present"
  else
    err ".env exists but TELEGRAM_API_ID / TELEGRAM_API_HASH are empty"
  fi
else
  err ".env missing — cp .env.example .env and fill in values"
fi

# Signing identities. Two are expected: Apple Development (Debug) and
# Developer ID Application (Release / /Applications / notarization) — D11.
ids="$(security find-identity -v -p codesigning 2>/dev/null)"
case "$ids" in
  *"Apple Development"*) ok "signing: Apple Development identity present (Debug)" ;;
  *) err "signing: no Apple Development identity — Debug builds cannot sign" ;;
esac
# Developer ID is only for release builds (make install / dmg / release), so a
# contributor clone without one is warned, not failed.
case "$ids" in
  *"Developer ID Application"*) ok "signing: Developer ID Application present (Release)" ;;
  *) warn "signing: no Developer ID Application identity — make install/dmg cannot sign" ;;
esac

# Notarization credentials (scope added at CP0 — a stored notarytool profile).
# Same default and override as the Makefile: NOTARY_PROFILE=<name>.
notary_profile="${NOTARY_PROFILE:-dictate-notary}"
if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  ok "notarytool keychain profile '$notary_profile' works"
else
  warn "notarytool profile '$notary_profile' unusable — make notarize will fail"
fi

# Network path to Telegram
if curl -m 8 -so /dev/null https://core.telegram.org; then
  ok "network: core.telegram.org reachable"
else
  warn "core.telegram.org not reachable (offline? proxy?)"
fi

# ---- TCC grants of the *calling* process (hard requirements for L3) ----------
screen_tcc="$(swift -e 'import CoreGraphics
print(CGPreflightScreenCaptureAccess())' 2>/dev/null | tail -1)"
if [ "$screen_tcc" = "true" ]; then
  ok "TCC: Screen Recording granted to this terminal"
else
  err "TCC: Screen Recording NOT granted — screencapture -l returns black frames"
fi

ax_tcc="$(swift -e 'import ApplicationServices
print(AXIsProcessTrusted())' 2>/dev/null | tail -1)"
if [ "$ax_tcc" = "true" ]; then
  ok "TCC: Accessibility granted to this terminal (CGEventPost clicks/keys)"
else
  err "TCC: Accessibility NOT granted — synthetic clicks and keystrokes will no-op"
fi

# Prove the grant end-to-end rather than trusting the preflight API: a revoked
# grant still reports true until the process restarts in some macOS builds.
shot="$(mktemp "${TMPDIR:-/tmp}/notchgram-preflight.XXXXXX").png"
screencapture -x -o -R 0,0,64,64 "$shot" 2>/dev/null || true
if [ -s "$shot" ]; then
  ok "screencapture produced $(wc -c < "$shot" | tr -d ' ') bytes"
else
  err "screencapture produced an empty file — Screen Recording is not really usable"
fi
rm -f "$shot"

# ---- Layering guard ----------------------------------------------------------
# TelegramCore is compiled into the ITest `tool` target too; an AppKit/SwiftUI
# import there breaks the headless harness at link time, far from the cause.
if [ -d "$repo_root/Sources/TelegramCore" ]; then
  if grep -rEn '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*import[[:space:]]+(AppKit|SwiftUI|Cocoa)\b' \
       "$repo_root/Sources/TelegramCore" >/dev/null 2>&1; then
    err "TelegramCore imports AppKit/SwiftUI/Cocoa — it must stay UI-free:"
    grep -rEn '^[[:space:]]*(@[A-Za-z]+[[:space:]]+)*import[[:space:]]+(AppKit|SwiftUI|Cocoa)\b' \
      "$repo_root/Sources/TelegramCore" | sed 's/^/       /'
  else
    ok "TelegramCore is free of AppKit/SwiftUI imports"
  fi
fi

# Physical notch (informational — synthetic-notch mode is the primary surface)
notch_inset="$(swift -e 'import AppKit
print(NSScreen.main?.safeAreaInsets.top ?? 0)' 2>/dev/null | tail -1)"
case "$notch_inset" in
  ""|0|0.0) warn "no physical notch on main display (safeAreaInsets.top=${notch_inset:-n/a}) — synthetic-notch mode covers this" ;;
  *)        ok "physical notch detected (safeAreaInsets.top=$notch_inset)" ;;
esac

screens="$(swift -e 'import AppKit
print(NSScreen.screens.count)' 2>/dev/null | tail -1)"
[ -n "$screens" ] && ok "displays attached: $screens"

echo
if [ "$fail" -eq 0 ]; then
  echo "Preflight PASSED"
else
  echo "Preflight FAILED"
  exit 1
fi
