#!/usr/bin/env bash
# Regenerates the public docs media in docs/media/ from DEMO MODE — fictional
# fixture content, no TDLib client, no real account, no network:
#
#   hero.gif      hover → unfold → browse a chat → album → viewer → fold
#   chatlist.png  chat.png  media.png  settings.png   (panel stills, 2x)
#   icon.png      512 px render of the app icon
#
#   make media            (builds Debug first)
#   scripts/capture-media.sh
#
# Capture paths, and why:
# - Stills use the in-app renderer (DebugBridge `screenshot`): no Screen
#   Recording grant, only the panel's own pixels, transparent outside the slab.
# - The GIF needs the unfold animation, which the in-app renderer cannot see
#   (it draws the pre-animation state until a spring settles). It uses a
#   window-scoped `screencapture -v -l <panel window>`: only that one window is
#   recorded, and demo mode paints a generated wallpaper behind the slab, so
#   nothing of the real desktop can appear. It runs only when this terminal
#   already holds the Screen Recording grant — it never asks for one; without
#   it the GIF is skipped and everything else is still produced.
# - The pointer in the GIF is drawn in post; the real cursor is never captured.
#
# Shared-state rule: a running NotchGram (e.g. the installed /Applications
# copy on the real account) is quit gracefully first (never SIGKILL, D20) and
# relaunched at the end. Only one instance ever runs at a time.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
cd "$repo"

APP="$repo/build/Build/Products/Debug/NotchGram.app"
INSTALLED="/Applications/NotchGram.app"
OUT="$repo/docs/media"
WORK="$repo/.artifacts/media"
BRIDGE="$here/debug-bridge.sh"

for tool in jq ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "capture-media: needs $tool" >&2; exit 1; }
done
[ -d "$APP" ] || { echo "capture-media: no Debug build at $APP — run make build" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$WORK" && mkdir -p "$WORK"

bridge() { bash "$BRIDGE" cmd "$1"; }

# ---------------------------------------------------------------- lifecycle

installed_was_running=0
if pgrep -f "$INSTALLED/Contents/MacOS/NotchGram" >/dev/null 2>&1; then
  installed_was_running=1
fi

finish() {
  bash "$here/quit-app.sh" >/dev/null 2>&1 || true
  if [ "$installed_was_running" = 1 ] && [ -d "$INSTALLED" ]; then
    open -g "$INSTALLED" || true
    echo "capture-media: relaunched $INSTALLED"
  fi
}
trap finish EXIT

launch_demo() {
  bash "$here/quit-app.sh" >/dev/null
  # `open --env` is the only way the variables reach a LaunchServices launch.
  open -n -g -o "$WORK/demo.out.log" --stderr "$WORK/demo.err.log" \
    --env NOTCHGRAM_DEMO=1 --env NOTCHGRAM_DEBUG_BRIDGE=1 "$APP"
  local status=""
  for _ in $(seq 1 60); do
    status="$(bash "$BRIDGE" status 2>/dev/null)" && break
    sleep 0.25
  done
  # Never take a picture of anything but demo mode: a missing variable would
  # mean the real account is on screen.
  if [ "$(printf '%s' "$status" | jq -r '.demo // false')" != "true" ]; then
    echo "capture-media: app is NOT in demo mode — aborting" >&2
    exit 1
  fi
  printf '%s' "$status"
}

# ------------------------------------------------------------------- stills

echo "capture-media: stills"
status="$(launch_demo)"
screen="$(printf '%s' "$status" | jq -r '.panels[0].screenUUID')"

shot() {
  bridge "{\"command\":\"screenshot\",\"path\":\"$OUT/$1\",\"screen\":\"$screen\"}" >/dev/null
  test -s "$OUT/$1" || { echo "capture-media: $1 is empty" >&2; exit 1; }
}

MAYA=201
TRAIL_CREW=-1000000000012

bridge "{\"command\":\"expand\",\"screen\":\"$screen\"}" >/dev/null
sleep 1
shot chatlist.png
# Trail Crew first: the very first conversation opened after launch can stop
# its opening scroll a few points short of the bottom, which leaves the
# scroll-to-bottom button up in the shot.
bridge "{\"command\":\"openChat\",\"chatId\":$TRAIL_CREW}" >/dev/null
sleep 4   # the opening scroll settles and the scroll-to-bottom button fades
shot media.png
bridge "{\"command\":\"openChat\",\"chatId\":$MAYA}" >/dev/null
sleep 4
shot chat.png
bridge '{"command":"setPane","state":"settings"}' >/dev/null
sleep 0.8
shot settings.png
bridge '{"command":"setPane","state":"conversation"}' >/dev/null

echo "capture-media: icon"
swift "$here/make-icon.swift" "$repo/Sources/App/Assets.xcassets/AppIcon.appiconset" \
  "$OUT/icon.png" >/dev/null

# --------------------------------------------------------------------- GIF

cat > "$WORK/preflight.swift" <<'SWIFT'
import CoreGraphics
// Preflight only: never CGRequestScreenCaptureAccess — that would prompt.
print(CGPreflightScreenCaptureAccess() ? "yes" : "no")
SWIFT
if [ "$(swift "$WORK/preflight.swift" 2>/dev/null)" != "yes" ]; then
  echo "capture-media: no Screen Recording grant for this terminal — skipping hero.gif" >&2
  exit 0
fi

echo "capture-media: hero.gif"
status="$(launch_demo)"     # fresh state: unread badges back, no chat open
screen="$(printf '%s' "$status" | jq -r '.panels[0].screenUUID')"
bridge '{"command":"setBackdrop","enabled":true}' >/dev/null
# A panel over a physical cut-out paints nothing while collapsed (the hardware
# is the notch), which would record as black. The drawn tab keeps the
# collapsed state visible; the setting lands in demo mode's own preference
# suite, never the app's real domain.
bridge '{"command":"forceSynthetic","enabled":true}' >/dev/null
bridge '{"command":"collapse"}' >/dev/null
sleep 1
wid="$(bash "$BRIDGE" status | jq -r '.windowNumber')"

# Timeline (seconds from the start of the recording). The pointer track below
# is keyed to the same marks.
T_EXPAND=1.3; T_MAYA=3.2; T_TRAIL=6.0; T_PHOTO=8.6; T_CLOSE=10.8; T_FOLD=12.0
DURATION=13.6
ALBUM_PHOTO=$((204 << 20))   # first photo of the Trail Crew album

screencapture -x -o -v -V"$DURATION" -l"$wid" "$WORK/hero.mov" &
recorder=$!
start=$(python3 -c 'import time; print(time.time())')
at() {  # sleep until $1 seconds after $start
  python3 -c "import time; d=$start+$1-time.time(); time.sleep(max(0,d))"
}
at $T_EXPAND; bridge "{\"command\":\"expand\",\"screen\":\"$screen\"}" >/dev/null
at $T_MAYA;   bridge "{\"command\":\"openChat\",\"chatId\":$MAYA}" >/dev/null
at $T_TRAIL;  bridge "{\"command\":\"openChat\",\"chatId\":$TRAIL_CREW}" >/dev/null
at $T_PHOTO;  bridge "{\"command\":\"openMedia\",\"chatId\":$ALBUM_PHOTO}" >/dev/null
at $T_CLOSE;  bridge '{"command":"closeMedia"}' >/dev/null
at $T_FOLD;   bridge '{"command":"collapse"}' >/dev/null
wait "$recorder"
test -s "$WORK/hero.mov" || { echo "capture-media: recording is empty" >&2; exit 1; }

# The recorder starts a beat after it is launched. Find the unfold in the
# footage (the first frame that differs from the opening one) and shift the
# pointer track by the difference.
onset=$(ffmpeg -hide_banner -i "$WORK/hero.mov" -vf "scale=220:-1,signalstats,metadata=print:key=lavfi.signalstats.YAVG" \
  -f null - 2>&1 | python3 -c '
import re, sys
times, values = [], []
t = None
for line in sys.stdin:
    m = re.search(r"pts_time:([0-9.]+)", line)
    if m: t = float(m.group(1))
    m = re.search(r"YAVG=([0-9.]+)", line)
    if m and t is not None: times.append(t); values.append(float(m.group(1)))
base = values[0]
print(next((t for t, v in zip(times, values) if abs(v - base) > 1.0), 0))')
shift=$(python3 -c "print(max(-1.0, min(1.0, $onset - $T_EXPAND - 0.03)))")
echo "capture-media: unfold onset ${onset}s, pointer shift ${shift}s"

# Pointer sprites, drawn here — the real cursor is never recorded.
cat > "$WORK/sprites.swift" <<'SWIFT'
import AppKit
func png(_ size: NSSize, _ path: String, _ draw: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
let dir = CommandLine.arguments[1]
// A classic arrow, 2x, tip at the top-left pixel.
png(NSSize(width: 44, height: 64), dir + "/cursor.png") {
    let p = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(3, 61), (3, 15), (14, 25), (21, 9), (28, 12), (21, 28), (36, 28)]
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
    for pt in pts.dropFirst() { p.line(to: NSPoint(x: pt.0, y: pt.1)) }
    p.close()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor.black.setFill(); p.fill()
    NSGraphicsContext.restoreGraphicsState()
    p.lineWidth = 3; p.lineJoinStyle = .round
    NSColor.black.setStroke(); p.stroke()
    NSColor.white.setFill(); p.fill()
}
// The click ring.
png(NSSize(width: 64, height: 64), dir + "/ring.png") {
    let ring = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 52, height: 52))
    ring.lineWidth = 4
    NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 0.9).setStroke()
    ring.stroke()
}
SWIFT
swift "$WORK/sprites.swift" "$WORK"

# The pointer track: (time, x, y) in panel points, eased between keyframes.
# Points are the rows/photo/close button as laid out in the default 880×580
# panel; the cursor arrives a beat before each command fires.
read -r cursor_x cursor_y ring_enable < <(python3 - "$shift" <<'PY'
import sys
shift = float(sys.argv[1])
keys = [  # t, x, y   (points)
    (0.0, 700, 430), (1.0, 446, 16),            # glide up to the notch
    (1.7, 446, 16), (2.9, 150, 128),            # hover, then onto Maya's row
    (3.5, 150, 128), (5.6, 150, 296),           # down to Trail Crew
    (6.6, 150, 296), (8.3, 400, 250),           # over to the album
    (9.2, 400, 250), (10.5, 841, 58),           # up to the viewer's close
    (11.1, 841, 58), (11.8, 700, 520),          # and away — the panel folds
    (13.6, 700, 430),
]
clicks = [3.2, 6.0, 8.6, 10.8]
def expr(axis):
    out = str(keys[-1][axis] * 2)
    for (t0, *a), (t1, *b) in reversed(list(zip(keys, keys[1:]))):
        t0 += shift; t1 += shift
        v0, v1 = a[axis - 1] * 2, b[axis - 1] * 2
        p = f"clip((t-{t0:.3f})/{t1 - t0:.3f},0,1)"
        seg = f"({v0}+({v1 - v0})*({p})*({p})*(3-2*({p})))"
        out = f"if(lt(t,{t1:.3f}),{seg},{out})"
    return out
ring = "+".join(f"between(t,{c + shift:.3f},{c + shift + 0.28:.3f})" for c in clicks)
print(expr(1), expr(2), ring)
PY
)

ffmpeg -loglevel error -y -i "$WORK/hero.mov" -loop 1 -i "$WORK/cursor.png" -loop 1 -i "$WORK/ring.png" \
  -filter_complex "\
[0:v]fps=20,setpts=PTS-STARTPTS[v];\
[v][2:v]overlay=x='${cursor_x}-32':y='${cursor_y}-32':enable='${ring_enable}':shortest=1[r];\
[r][1:v]overlay=x='${cursor_x}-3':y='${cursor_y}-3':shortest=1,\
scale=880:-1:flags=lanczos,split[a][b];\
[a]palettegen=max_colors=192:stats_mode=diff[p];\
[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -t "$DURATION" -loop 0 "$OUT/hero.gif"

echo "capture-media: done"
ls -la "$OUT"
