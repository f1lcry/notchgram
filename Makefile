APP_NAME  := NotchGram
BUNDLE_ID := com.f1lcry.notchgram
PROJECT   := $(APP_NAME).xcodeproj
BUILD_DIR := build
ARTIFACTS := .artifacts

# SPM checkouts live OUTSIDE the repo on purpose: this session runs in a git
# worktree, and `-clonedSourcePackagesDirPath` defaults to somewhere under
# -derivedDataPath, so a `make clean` (or a second worktree) would otherwise
# cost another 343 MB TDLibFramework download.
SPM_DIR ?= $(HOME)/Library/Caches/$(APP_NAME)/spm

# One shared invocation. NEVER write a bare `xcodebuild` line — every flag here
# is load-bearing (see docs/sessions/session-01-plan.md §3.8).
XCB_BASE := xcodebuild -project $(PROJECT) \
	-derivedDataPath $(BUILD_DIR) \
	-clonedSourcePackagesDirPath "$(SPM_DIR)" \
	-hideShellScriptEnvironment \
	-quiet
XCB := $(XCB_BASE) -destination 'platform=macOS,arch=arm64'
# The shipped build is Apple silicon only, on purpose (D44). Every Mac with a
# notch is Apple silicon; macOS 26 runs on four 2019–20 Intel models, which
# could only use the synthetic notch, and nobody here can exercise an x86_64
# slice. Measured: a universal DMG is 62 MB against 30 MB — TDLib's static
# library is ~110 MB per architecture — and every Sparkle update downloads the
# whole image. The destination alone does NOT thin a Release build (measured:
# Release ignores the destination's arch and builds ARCHS_STANDARD), hence the
# explicit ARCHS. TDLibFramework's macOS slice is arm64_x86_64, so going
# universal is dropping `ARCHS=arm64` here and `depends_on arch:` in the cask.
# (Sparkle ships as a prebuilt universal binary either way; it is ~3 MB.)
XCB_RELEASE := $(XCB_BASE) -destination 'generic/platform=macOS' ARCHS=arm64

DEBUG_APP   := $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app
ITEST_BIN   := $(BUILD_DIR)/Build/Products/Debug/notchgram-itest
INSTALL_PATH := /Applications/$(APP_NAME).app

# Release signing and notarization only; `make build` / `make test` need
# neither. codesign matches SIGN_ID as a substring of the certificate's common
# name, so the default picks the keychain's only Developer ID Application
# identity. With several, or for another developer account, override both, e.g.
#   make dmg SIGN_ID="Developer ID Application: Jane Doe (ABCDE12345)" NOTARY_PROFILE=my-notary
# (create the profile once with `xcrun notarytool store-credentials`).
SIGN_ID        ?= Developer ID Application
NOTARY_PROFILE ?= dictate-notary
DMG_STAGE      := $(BUILD_DIR)/dmg
NOTARIZE_ZIP   := $(BUILD_DIR)/$(APP_NAME)-notarize.zip
VERSION         = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(abspath $(RELEASE_APP))/Contents/Info.plist" 2>/dev/null)
DMG_PATH        = $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

# DebugBridge (D18): HTTP over a Unix domain socket. Not loopback TCP — macOS
# gates local-network access per app and the Release build never received TCP
# connections unattended. A missing socket == app not running.
BRIDGE_SOCKET := $(HOME)/Library/Application Support/$(APP_NAME)/debug.sock

.PHONY: preflight deps generate build release-build test uitest itest login run quit \
        install screenshot logs clean distclean dmg notarize notarize-app release sign-release \
        verify-release

preflight:
	bash scripts/preflight.sh

# Kept separate from `build` on purpose: the TDLibFramework artifact is 343 MB
# and an implicit download inside a build reads as a hang.
deps: generate
	$(XCB) -scheme $(APP_NAME) -resolvePackageDependencies

generate:
	bash scripts/gen-secrets.sh
	xcodegen generate

build: generate
	$(XCB) -scheme $(APP_NAME) -configuration Debug build

release-build: generate
	$(XCB_RELEASE) -scheme $(APP_NAME) -configuration Release build

test: generate
	@mkdir -p $(ARTIFACTS)
	@rm -rf $(ARTIFACTS)/test.xcresult
	$(XCB) -scheme $(APP_NAME) -configuration Debug \
		-resultBundlePath $(ARTIFACTS)/test.xcresult test
	@xcrun xcresulttool get test-results summary --path $(ARTIFACTS)/test.xcresult --compact

uitest: generate
	@mkdir -p $(ARTIFACTS)
	@rm -rf $(ARTIFACTS)/uitest.xcresult
	$(XCB) -scheme $(APP_NAME) -configuration Debug \
		-only-testing:NotchGramUITests \
		-resultBundlePath $(ARTIFACTS)/uitest.xcresult test

itest: generate
	$(XCB) -scheme ITest -configuration Debug build
	@mkdir -p $(ARTIFACTS)
	$(ITEST_BIN) --report $(ARTIFACTS)/itest.json

# Founder-run fallback for CP1 if the in-panel auth flow ever blocks.
login: generate
	$(XCB) -scheme ITest -configuration Debug build
	$(ITEST_BIN) --interactive-login

# `open -a` loses the streams; executing Contents/MacOS/NotchGram directly keeps
# them but skips LaunchServices registration (breaking `open notchgram://`).
run: build
	@mkdir -p $(ARTIFACTS)
	@# Quit first, always. The Debug and Release bundles share a bundle id AND
	@# the same accounts/<id>/db directory, so `open -n` on top of a running
	@# copy puts two TDLib clients on one encrypted SQLite database — the exact
	@# corruption D20 exists to prevent, and it would cost a re-login.
	@bash scripts/quit-app.sh || true
	@defaults write $(BUNDLE_ID) DebugBridgeEnabled -bool YES
	open -n -g -o "$(abspath $(ARTIFACTS))/run.out.log" \
		--stderr "$(abspath $(ARTIFACTS))/run.err.log" "$(DEBUG_APP)"
	@echo "launched — logs in $(ARTIFACTS)/run.{out,err}.log"

# NEVER pkill -9 (D20): TDLib holds an encrypted SQLite open and a corrupt DB
# after CP1 costs the founder a re-login.
quit:
	@bash scripts/quit-app.sh

install: release-build sign-release
	@bash scripts/quit-app.sh || true
	rm -rf "$(INSTALL_PATH)"
	ditto "$(RELEASE_APP)" "$(INSTALL_PATH)"
	@codesign -dvv "$(INSTALL_PATH)" 2>&1 | grep -q 'Authority=Developer ID Application' \
		|| { echo "install: /Applications copy is NOT Developer ID signed"; exit 1; }
	@echo "Installed $(INSTALL_PATH) (Developer ID)"

# One identity per installed bundle, permanently (D11 as amended): alternating
# leaf certificates changes the code requirement, which invalidates SMAppService
# login-item registration and can re-trigger TCC prompts.
#
# Signing is inside-out. Despite `embed: false` and the xcframework being a
# *static* library (its symbols land directly in our binary — `otool -L` shows no
# TDLib dependency), Xcode still drops a ~51 KB vestigial dynamic
# TDLibFramework.framework stub into Contents/Frameworks. Nested code keeps the
# Apple Development signature from the build, and notarization requires
# Developer ID on EVERY binary, so it has to be re-signed before the outer app.
#
# Sparkle (D43) is a real dynamic framework with nested executables. Each one
# keeps the build's Apple Development signature, so they are signed first,
# innermost out — exactly as Dictate does — and the framework is sealed last.
# Re-signing a nested binary *after* its framework would break that seal, which
# is why Sparkle is excluded from the generic loop below.
SPARKLE_FW = $(RELEASE_APP)/Contents/Frameworks/Sparkle.framework

sign-release:
	@if [ -d "$(SPARKLE_FW)" ]; then \
		set -e; \
		echo "re-signing Sparkle.framework (inside-out)"; \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(SPARKLE_FW)/Versions/B/Autoupdate"; \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(SPARKLE_FW)/Versions/B/Updater.app"; \
		codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$(SIGN_ID)" "$(SPARKLE_FW)/Versions/B/XPCServices/Downloader.xpc"; \
		codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$(SIGN_ID)" "$(SPARKLE_FW)/Versions/B/XPCServices/Installer.xpc"; \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(SPARKLE_FW)"; \
	fi
	@for fw in "$(RELEASE_APP)"/Contents/Frameworks/*.framework; do \
		[ -d "$$fw" ] || continue; \
		case "$$fw" in */Sparkle.framework) continue ;; esac; \
		echo "re-signing $$fw"; \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$$fw" || exit 1; \
	done
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" "$(RELEASE_APP)"
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	@codesign -dvv "$(RELEASE_APP)" 2>&1 | grep -q 'Authority=Developer ID Application' \
		|| { echo "sign-release: app is NOT Developer ID signed"; exit 1; }

# Notarize the .app itself and staple the ticket INTO the bundle, so the app is
# self-sufficient however it travels. `notarytool` will not take a bare .app —
# it needs a zip/dmg/pkg container — but the ticket is stapled to the app, not
# to the throwaway zip.
#
# Note for the record: the submitted binary contains the Telegram api_id/hash,
# because every Telegram client ships its own. That upload is expected and
# unavoidable, not a leak — the rule is "never in git, never in logs".
# The public build must not contain the agent control channel (D43): not
# disabled, *absent*. Checked on the main executable only — Sparkle's own
# binaries may legitimately share generic strings. The markers are specific on
# purpose; bare "Debug" would match legitimate symbols like `isDebugForced`.
RELEASE_FORBIDDEN := debug.sock DebugBridgeEnabled NOTCHGRAM_DEBUG_BRIDGE DebugServer \
	DebugRouter DebugCommandRequest DebugAuthStates DebugFixtureScenarios \
	CheckpointNotifier CHECKPOINT.md osascript \
	NOTCHGRAM_DEMO DemoContent DemoArtwork DemoStage enterOfflineDemo \
	openOffline setBackdrop openMedia closeMedia Hartmann

verify-release:
	@bin="$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"; \
	test -f "$$bin" || { echo "verify-release: $$bin missing — run make release-build"; exit 1; }; \
	found=0; \
	for marker in $(RELEASE_FORBIDDEN); do \
		if strings -a "$$bin" | grep -qF "$$marker"; then echo "verify-release: '$$marker' in strings"; found=1; fi; \
		if nm -a "$$bin" 2>/dev/null | grep -qF "$$marker"; then echo "verify-release: '$$marker' in symbols"; found=1; fi; \
	done; \
	[ "$$found" = 0 ] || { echo "verify-release: FAILED — DebugBridge/CheckpointNotifier/demo mode leaked into Release"; exit 1; }; \
	plist="$(RELEASE_APP)/Contents/Info.plist"; \
	for key in SUFeedURL SUPublicEDKey; do \
		/usr/libexec/PlistBuddy -c "Print :$$key" "$$plist" >/dev/null 2>&1 \
			|| { echo "verify-release: Info.plist lacks $$key"; exit 1; }; \
	done; \
	test -s "$(RELEASE_APP)/Contents/Resources/THIRD_PARTY_NOTICES.md" \
		|| { echo "verify-release: Contents/Resources/THIRD_PARTY_NOTICES.md missing (licence obligations)"; exit 1; }; \
	echo "verify-release: no debug markers; archs: $$(lipo -archs "$$bin"); Sparkle keys + notices present"

notarize-app: release-build sign-release verify-release
	rm -f "$(NOTARIZE_ZIP)"
	ditto -c -k --keepParent "$(RELEASE_APP)" "$(NOTARIZE_ZIP)"
	xcrun notarytool submit "$(NOTARIZE_ZIP)" --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple "$(RELEASE_APP)"
	spctl -a -vvv -t exec "$(RELEASE_APP)"
	@echo "Notarized + stapled: $(RELEASE_APP)"

# Built from the already-stapled app, so a copy dragged out of the DMG carries
# its own ticket even offline.
#
# SKIP_NOTARIZE=1 builds the same signed image from the Developer ID app
# WITHOUT a notarization round trip — only for `release.sh --dry-run
# --skip-notarize`, when no notarytool profile is at hand. Gatekeeper rejects
# such an image on any other Mac; release.sh refuses to publish one.
dmg: $(if $(SKIP_NOTARIZE),release-build sign-release verify-release,notarize-app)
	rm -rf "$(DMG_STAGE)" && mkdir -p "$(DMG_STAGE)"
	ditto "$(RELEASE_APP)" "$(DMG_STAGE)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_STAGE)/Applications"
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder "$(DMG_STAGE)" \
		-ov -format UDZO "$(DMG_PATH)"
	@# A notarized but unsigned image still mounts, but `spctl -t open` calls it
	@# "no usable signature" and nothing vouches for the container itself.
	codesign --force --timestamp --sign "$(SIGN_ID)" "$(DMG_PATH)"
	@# The staging copy is a second NotchGram.app on disk; the DMG has the bytes.
	rm -rf "$(DMG_STAGE)"
	@echo "DMG: $(DMG_PATH)"

notarize: dmg
	xcrun notarytool submit "$(DMG_PATH)" --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"
	spctl -a -vvv -t open --context context:primary-signature "$(DMG_PATH)"
	@echo "Notarized + stapled: $(DMG_PATH)"

# Publishes one release (scripts/release.sh): CHANGELOG section → version bump
# → notarized DMG → Sparkle signature → release commit + tag, pushed → GitHub
# release on f1lcry/notchgram → appcast on the `feed` release → Homebrew cask.
# On main, clean tree only. DRY_RUN=1 does everything short of publishing and
# leaves the tree as it found it; DRY_RUN=1 SKIP_NOTARIZE=1 also skips Apple's
# notary service (no notarytool profile on this machine).
release:
	@test "$(origin VERSION)" = "command line" \
		|| { echo "usage: make release VERSION=x.y.z [DRY_RUN=1 [SKIP_NOTARIZE=1]]"; exit 1; }
	bash scripts/release.sh $(if $(DRY_RUN),--dry-run) $(if $(SKIP_NOTARIZE),--skip-notarize) $(VERSION)

screenshot:
	@bash scripts/screenshot.sh

logs:
	log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

# Deliberately does NOT touch $(SPM_DIR) — see the note on SPM_DIR above.
clean:
	rm -rf $(BUILD_DIR) $(ARTIFACTS)/*.xcresult

distclean: clean
	rm -rf $(PROJECT) Sources/Info.plist Sources/TelegramCore/Secrets.generated.swift

# --- Docs media (demo mode) -------------------------------------------------
# Regenerates docs/media/ (hero.gif, chatlist/chat/media/settings.png,
# icon.png) from NOTCHGRAM_DEMO=1 fixture content — no TDLib client, no real
# account. See scripts/capture-media.sh for the capture paths it uses.
.PHONY: media
media: build
	bash scripts/capture-media.sh
