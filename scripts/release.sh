#!/bin/bash
# Publishes one NotchGram release end to end. Run via
#
#     make release VERSION=x.y.z            # publish
#     make release VERSION=x.y.z DRY_RUN=1  # everything short of publishing
#
# Flow (mirrors Dictate's scripts/release.sh, adapted to a public repo that
# hosts its own releases):
#
#   0. preconditions — everything that can refuse, refuses before any change
#   1. CHANGELOG heading stamped with today's date, release notes rendered
#   2. version bump in project.yml (marketing version + build number)
#   3. Release build → Developer ID → notarized + stapled app → signed,
#      notarized + stapled DMG (`make notarize`; `make verify-release` gates it)
#   4. Gatekeeper / stapler checks on the DMG and the app inside it
#   5. Sparkle EdDSA signature (keychain account `notchgram`), verified against
#      the SUPublicEDKey the built app ships with
#   6. appcast.xml and the Homebrew cask staged under build/release-<version>/
#   --- a dry run stops here and restores project.yml and CHANGELOG.md ---
#   7. release commit + annotated tag, pushed with main (atomic)
#   8. GitHub release vX.Y.Z on f1lcry/notchgram with the DMG, marked Latest
#   9. appcast.xml uploaded to the fixed `feed` release (a prerelease, so it
#      never becomes "Latest")
#  10. Homebrew cask bumped and pushed in the f1lcry/homebrew-tap clone
#
# The commit and tag are pushed BEFORE the GitHub release on purpose: `gh
# release create` on a tag that does not exist remotely creates it at the
# remote's HEAD — the pre-bump commit — and the local tag could then never be
# pushed. With --verify-tag the release is bound to the exact released commit.
#
# Environment:
#   HOMEBREW_TAP_DIR  clone of f1lcry/homebrew-tap (default: ../homebrew-tap
#                     next to this repo; cloned there if absent)
#   SPM_DIR           SwiftPM checkout dir (default as in the Makefile)
#   NOTARY_PROFILE    notarytool keychain profile (default as in the Makefile)
set -euo pipefail

usage() { echo "usage: release.sh [--dry-run [--skip-notarize]] <x.y.z>" >&2; exit 2; }

DRY_RUN=0
# Dry run only: exercise everything except Apple's notary service, for a
# machine without a notarytool profile. Gatekeeper checks become informational.
SKIP_NOTARIZE=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || usage
[ "$SKIP_NOTARIZE" = 0 ] || [ "$DRY_RUN" = 1 ] || { echo "release: --skip-notarize is only allowed with --dry-run" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: '$VERSION' is not x.y.z" >&2; exit 2; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

APP_NAME="NotchGram"
REPO="f1lcry/notchgram"
TAP_REPO="f1lcry/homebrew-tap"
TAP_DIR="${HOMEBREW_TAP_DIR:-$(dirname "$REPO_DIR")/homebrew-tap}"
SPARKLE_ACCOUNT="notchgram"
SPM_DIR="${SPM_DIR:-$HOME/Library/Caches/$APP_NAME/spm}"
SPARKLE_BIN="$SPM_DIR/artifacts/sparkle/Sparkle/bin"
NOTARY_PROFILE="${NOTARY_PROFILE:-dictate-notary}"
TAG="v$VERSION"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="build/$DMG_NAME"
RELEASE_APP="build/Build/Products/Release/$APP_NAME.app"
ASSET_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
RELEASE_PAGE="https://github.com/$REPO/releases/tag/$TAG"
FEED_URL="https://github.com/$REPO/releases/download/feed/appcast.xml"
CASK_TEMPLATE="packaging/homebrew-tap/Casks/notchgram.rb"
OUT="build/release-$VERSION"

say() { printf '\n==> %s\n' "$*"; }
refuse() { echo "release: $*" >&2; exit 1; }
# A dry run reports what a real run would refuse, then carries on, so the
# pipeline can be exercised from a branch or a dirty tree.
gate() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "release (dry run): a real run would refuse — $*" >&2
    else
        refuse "$*"
    fi
}

# ---------------------------------------------------------------------------
# 0. Preconditions
mode=""; [ "$DRY_RUN" = 1 ] && mode=" (dry run)"
say "Preconditions for $APP_NAME $VERSION$mode"

for tool in gh python3 xcrun codesign hdiutil shasum swift; do
    command -v "$tool" >/dev/null || refuse "$tool not found"
done

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || gate "releases are cut from main (on $branch)"
if ! git diff --quiet || ! git diff --cached --quiet; then
    gate "working tree has uncommitted changes"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    refuse "tag $TAG already exists locally"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null)" ]; then
    refuse "tag $TAG already exists on origin"
fi
if [ "$DRY_RUN" = 0 ]; then
    gh auth status >/dev/null 2>&1 || refuse "gh is not authenticated"
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || refuse "main is not at origin/main — pull or push first"
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    refuse "release $TAG already exists on $REPO"
fi

grep -qE "^## $VERSION( |$)" CHANGELOG.md || refuse "CHANGELOG.md has no '## $VERSION' section"

[ -x "$SPARKLE_BIN/sign_update" ] || refuse "Sparkle tools missing at $SPARKLE_BIN — run 'make deps'"
yml_key="$(sed -n 's/^ *SUPublicEDKey: *//p' project.yml)"
keychain_key="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)"
[ -n "$keychain_key" ] || refuse "no Sparkle key for keychain account '$SPARKLE_ACCOUNT' (restore it: generate_keys --account $SPARKLE_ACCOUNT -f <backup>)"
[ "$keychain_key" = "$yml_key" ] \
    || refuse "keychain account '$SPARKLE_ACCOUNT' holds a different key than project.yml's SUPublicEDKey"

if [ "$SKIP_NOTARIZE" = 0 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || refuse "notarytool profile '$NOTARY_PROFILE' unusable (a dry run can pass --skip-notarize)"
fi

if [ "$DRY_RUN" = 0 ]; then
    if [ -d "$TAP_DIR/.git" ]; then
        if ! git -C "$TAP_DIR" diff --quiet || ! git -C "$TAP_DIR" diff --cached --quiet; then
            refuse "$TAP_DIR has uncommitted changes"
        fi
    else
        gh repo view "$TAP_REPO" >/dev/null 2>&1 \
            || refuse "$TAP_REPO not reachable and no clone at $TAP_DIR — create the tap first (packaging/homebrew-tap)"
    fi
fi
echo "preconditions ok"

# ---------------------------------------------------------------------------
# From here on the tree changes. project.yml and CHANGELOG.md are restored on
# any exit until the release commit exists (always, in a dry run); after that
# the error handler says exactly which publishing steps are left.
BACKUP="$(mktemp -d -t notchgram-release)"
cp project.yml CHANGELOG.md "$CASK_TEMPLATE" "$BACKUP/"
STAGE="prepare"   # prepare → committed → pushed → released → feed → done

remaining() {
    case "$STAGE" in
        committed)
            echo "  git rev-parse -q --verify refs/tags/$TAG || git tag -a $TAG -m '$APP_NAME $VERSION'"
            echo "  git push --atomic origin main $TAG" ;;
    esac
    case "$STAGE" in
        committed|pushed)
            echo "  gh release create $TAG --repo $REPO --verify-tag --latest --title '$APP_NAME $VERSION' --notes-file $OUT/notes.md $DMG" ;;
    esac
    case "$STAGE" in
        committed|pushed|released)
            echo "  gh release view feed --repo $REPO || gh release create feed --repo $REPO --prerelease --latest=false --title 'Sparkle feed' --notes 'Rolling appcast.xml for the in-app updater. Not a download.'"
            echo "  gh release upload feed $OUT/appcast.xml --repo $REPO --clobber" ;;
    esac
    case "$STAGE" in
        committed|pushed|released|feed)
            echo "  cp $OUT/notchgram.rb $TAP_DIR/Casks/notchgram.rb && git -C $TAP_DIR commit -am 'notchgram $VERSION' && git -C $TAP_DIR push" ;;
    esac
}

finish() {
    local status=$?
    trap - EXIT
    if [ "$STAGE" = "prepare" ]; then
        cp "$BACKUP/project.yml" "$BACKUP/CHANGELOG.md" .
        cp "$BACKUP/$(basename "$CASK_TEMPLATE")" "$CASK_TEMPLATE"
        if [ "$status" != 0 ]; then
            echo "release $VERSION failed (exit $status); project.yml and CHANGELOG.md restored, nothing was published" >&2
        fi
    elif [ "$STAGE" != "done" ]; then
        echo >&2
        echo "release $VERSION stopped (exit $status) after stage '$STAGE'. Staged files are in $OUT. Remaining steps:" >&2
        remaining >&2
    fi
    rm -rf "$BACKUP"
    exit "$status"
}
trap finish EXIT

# ---------------------------------------------------------------------------
# 1. Release notes. "Unreleased" becomes today's date; release_notes.py still
# refuses an unstamped heading, so a stamping bug cannot ship "Unreleased".
say "Release notes"
TODAY="$(date -u +%F)"
VERSION_RE="${VERSION//./\\.}"
sed -i '' -E "s/^## $VERSION_RE( +(—|–|-+))? +[Uu]nreleased *$/## $VERSION — $TODAY/" CHANGELOG.md
mkdir -p "$OUT"
python3 scripts/release_notes.py CHANGELOG.md "$VERSION" > "$OUT/notes.md"
python3 scripts/release_notes.py CHANGELOG.md "$VERSION" --html > "$OUT/notes.html"
grep -E "^## $VERSION" CHANGELOG.md

# ---------------------------------------------------------------------------
# 2. Version bump — project.yml is the source of truth for both numbers, and
# the build number is what Sparkle compares, so it only ever goes up.
say "Version bump"
[ "$(grep -cE '^ *MARKETING_VERSION:' project.yml)" = 1 ] || refuse "expected exactly one MARKETING_VERSION in project.yml"
[ "$(grep -cE '^ *CURRENT_PROJECT_VERSION:' project.yml)" = 1 ] || refuse "expected exactly one CURRENT_PROJECT_VERSION in project.yml"
current_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *//p' project.yml)"
new_build=$((current_build + 1))
sed -i '' -E "s/^( *MARKETING_VERSION:).*/\1 $VERSION/" project.yml
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION:).*/\1 $new_build/" project.yml
echo "MARKETING_VERSION $VERSION, CURRENT_PROJECT_VERSION $current_build → $new_build"

# ---------------------------------------------------------------------------
# 3. Build, sign, gate, notarize, staple, DMG. Under `make release` the
# sub-make inherits the command line (VERSION, and any SIGN_ID /
# NOTARY_PROFILE override); the version check below catches a bump that did
# not reach the built app.
rm -f "$DMG"
if [ "$SKIP_NOTARIZE" = 1 ]; then
    say "Signed DMG, NOT notarized (make dmg SKIP_NOTARIZE=1)"
    make dmg SKIP_NOTARIZE=1
else
    say "Notarized DMG (make notarize)"
    make notarize NOTARY_PROFILE="$NOTARY_PROFILE" SKIP_NOTARIZE=
fi
[ -f "$DMG" ] || refuse "$DMG was not produced"

plist="$RELEASE_APP/Contents/Info.plist"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
built_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[ "$built_version" = "$VERSION" ] && [ "$built_build" = "$new_build" ] \
    || refuse "built app is $built_version ($built_build), expected $VERSION ($new_build)"

# ---------------------------------------------------------------------------
# 4. What a downloader's Mac will check.
say "Gatekeeper checks"
# Without notarization there is no ticket to validate and Gatekeeper must
# reject; those checks are then run for the record only.
gk() {
    if [ "$SKIP_NOTARIZE" = 1 ]; then
        "$@" 2>&1 | sed 's/^/  (not notarized, informational) /' || true
    else
        "$@"
    fi
}
codesign --verify --strict --verbose=2 "$DMG"
gk xcrun stapler validate "$DMG"
gk spctl -a -vvv -t open --context context:primary-signature "$DMG"
# `-t install` assesses installer packages; on a disk image it may be
# rejected even when everything is right, so it is reported, not enforced.
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  (informational) /' || true

MOUNT="$(mktemp -d -t notchgram-dmg)"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
detach() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -force -quiet "$MOUNT" || true; }
# Chained with && on purpose: `set -e` does not apply inside the left side of
# `||`, so separate lines there would let a failed check fall through.
codesign --verify --deep --strict --verbose=2 "$MOUNT/$APP_NAME.app" \
    && [ -L "$MOUNT/Applications" ] \
    || { detach; refuse "the app inside $DMG failed its signature check (or the /Applications link is missing)"; }
if [ "$SKIP_NOTARIZE" = 1 ]; then
    gk xcrun stapler validate "$MOUNT/$APP_NAME.app"
    gk spctl -a -vvv -t exec "$MOUNT/$APP_NAME.app"
else
    xcrun stapler validate "$MOUNT/$APP_NAME.app" \
        && spctl -a -vvv -t exec "$MOUNT/$APP_NAME.app" \
        || { detach; refuse "the app inside $DMG is not stapled / not accepted by Gatekeeper"; }
fi
detach
rmdir "$MOUNT" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Sparkle signature, checked twice: by sign_update against the keychain
# pair, and independently against the key the shipped app trusts.
say "Sparkle EdDSA signature (account $SPARKLE_ACCOUNT)"
sig_output="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
ED_SIG="$(echo "$sig_output" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$sig_output" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || refuse "could not parse sign_update output"
[ "$LENGTH" = "$(stat -f %z "$DMG")" ] || refuse "sign_update length $LENGTH != DMG size"
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$DMG" "$ED_SIG"
shipped_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist")"
swift scripts/verify_ed_signature.swift "$DMG" "$ED_SIG" "$shipped_key"

# ---------------------------------------------------------------------------
# 6. Stage the feed and the cask.
say "Appcast"
rm -f "$OUT/appcast.xml"
if gh release download feed --repo "$REPO" --pattern appcast.xml --dir "$OUT" >/dev/null 2>&1; then
    echo "starting from the published feed"
else
    echo "no published feed yet — starting a new one"
fi
python3 scripts/appcast.py "$OUT/appcast.xml" \
    --version "$VERSION" --build "$new_build" \
    --url "$ASSET_URL" --length "$LENGTH" --signature "$ED_SIG" \
    --notes-html "$OUT/notes.html" --min-system 26.0 --release-page "$RELEASE_PAGE"
python3 -c "import sys, xml.dom.minidom as m; m.parse(sys.argv[1])" "$OUT/appcast.xml"

say "Homebrew cask"
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed -E -e "s/^(  version )\"[^\"]*\"/\1\"$VERSION\"/" \
       -e "s/^(  sha256 )\"[^\"]*\"/\1\"$SHA256\"/" \
       "$CASK_TEMPLATE" > "$OUT/notchgram.rb"
grep -q "version \"$VERSION\"" "$OUT/notchgram.rb" && grep -q "sha256 \"$SHA256\"" "$OUT/notchgram.rb" \
    || refuse "cask rewrite failed"
ruby -c "$OUT/notchgram.rb" >/dev/null
echo "version $VERSION, sha256 $SHA256"

if [ "$DRY_RUN" = 1 ]; then
    say "Dry run complete — nothing was committed, tagged, pushed or published"
    [ "$SKIP_NOTARIZE" = 0 ] || echo "  NOTE: --skip-notarize — this DMG is NOT notarized and must not be distributed"
    echo "  DMG:      $DMG ($LENGTH bytes, sha256 $SHA256)"
    echo "  notes:    $OUT/notes.md"
    echo "  appcast:  $OUT/appcast.xml (would be uploaded to $FEED_URL)"
    echo "  cask:     $OUT/notchgram.rb (would be pushed to $TAP_REPO)"
    echo "  release:  $TAG on $REPO, marked Latest"
    echo "project.yml and CHANGELOG.md are restored on exit."
    exit 0
fi

# ---------------------------------------------------------------------------
# 7. Release commit + tag, pushed together with main.
say "Release commit and tag"
cp "$OUT/notchgram.rb" "$CASK_TEMPLATE"
git add project.yml CHANGELOG.md "$CASK_TEMPLATE"
git commit -qm "chore: release $TAG"
# Committed: from here a failure must not restore the pre-bump files.
STAGE="committed"
git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push --atomic origin main "$TAG"
STAGE="pushed"

# ---------------------------------------------------------------------------
# 8. The GitHub release, bound to the pushed tag.
say "GitHub release $TAG"
gh release create "$TAG" --repo "$REPO" --verify-tag --latest \
    --title "$APP_NAME $VERSION" --notes-file "$OUT/notes.md" "$DMG"
STAGE="released"

# ---------------------------------------------------------------------------
# 9. The Sparkle feed: a rolling asset on a fixed prerelease, on the same
# host as the DMGs (raw.githubusercontent.com is DPI-blocked on some networks).
say "Sparkle feed"
if ! gh release view feed --repo "$REPO" >/dev/null 2>&1; then
    gh release create feed --repo "$REPO" --prerelease --latest=false \
        --title "Sparkle feed" \
        --notes "Rolling appcast.xml consumed by the in-app updater. Not a download — see the latest version release instead."
fi
gh release upload feed "$OUT/appcast.xml" --repo "$REPO" --clobber
STAGE="feed"
if curl -fsSL -o /dev/null "$FEED_URL"; then
    echo "feed reachable: $FEED_URL"
else
    echo "warning: $FEED_URL is not publicly reachable yet (private repo?) — installed apps cannot update until it is" >&2
fi

# ---------------------------------------------------------------------------
# 10. Homebrew tap.
say "Homebrew tap"
if [ ! -d "$TAP_DIR/.git" ]; then
    gh repo clone "$TAP_REPO" "$TAP_DIR"
fi
git -C "$TAP_DIR" pull -q --ff-only
mkdir -p "$TAP_DIR/Casks"
cp "$OUT/notchgram.rb" "$TAP_DIR/Casks/notchgram.rb"
git -C "$TAP_DIR" add Casks/notchgram.rb
git -C "$TAP_DIR" commit -qm "notchgram $VERSION"
git -C "$TAP_DIR" push -q
STAGE="done"

say "Released $APP_NAME $VERSION"
echo "  release: $RELEASE_PAGE"
echo "  DMG:     $ASSET_URL"
echo "  feed:    $FEED_URL"
echo "  brew:    brew install --cask f1lcry/tap/notchgram"
