#!/usr/bin/env bash
# Screenshots every authorization screen through DebugBridge.
#
# There is no account that visits waitPremiumPurchase, waitRegistration and
# waitOtherDeviceConfirmation in one session, so this is the only way all
# thirteen states get looked at — which is the point of `gotoAuthState`.
#
#   scripts/capture-auth-states.sh [output-dir]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$(cd "$here/.." && pwd)/.artifacts/auth-states}"
mkdir -p "$out"

states=(
  initializing waitPhoneNumber waitCode waitCodeSms waitCodeWord waitCodeMissedCall
  waitPassword waitRegistration waitEmailAddress waitEmailCode
  waitOtherDeviceConfirmation waitPremiumPurchase ready loggingOut closing closed
  unsupported
)

"$here/debug-bridge.sh" cmd '{"command":"expand"}' >/dev/null

for state in "${states[@]}"; do
  "$here/debug-bridge.sh" cmd "{\"command\":\"gotoAuthState\",\"state\":\"$state\"}" >/dev/null
  sleep 0.35
  "$here/debug-bridge.sh" cmd "{\"command\":\"screenshot\",\"path\":\"$out/$state.png\"}" >/dev/null
  printf '  %-28s %s\n' "$state" "$(wc -c < "$out/$state.png" | tr -d ' ') bytes"
done

# Hand the panel back to the real state, or the app is left lying to itself.
"$here/debug-bridge.sh" cmd '{"command":"gotoAuthState","state":"live"}' >/dev/null
"$here/debug-bridge.sh" cmd '{"command":"collapse"}' >/dev/null
echo "auth states → $out"
