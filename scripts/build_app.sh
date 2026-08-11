#!/usr/bin/env bash
# Assemble a .app bundle from the SwiftPM build output.
#
# Usage:
#   scripts/build_app.sh <flavor>
#     flavor: dev | release
#
# Output:
#   build/<flavor>/e05.app
#
# Both flavors copy the binary into the bundle (instead of
# symlinking) because ad-hoc signing embeds in the binary,
# and `swift build` would invalidate the signature on every
# rebuild if we shared inodes via a symlink. APFS clonefile
# makes the copy effectively zero-cost.

set -euo pipefail

FLAVOR="${1:-dev}"
# URL_HANDLER_RANK keeps `open e05://...` deterministic when both
# flavors are registered with Launch Services on the same machine:
# dev stays `Alternate` so a release install always wins, and a
# dev-only machine still has the only registered handler.
case "$FLAVOR" in
    dev)
        BUNDLE_ID="com.kawarimidoll.e05.debug"
        DISPLAY_NAME="e05[DEV]"
        BIN_SRC=".build/debug/e05"
        URL_HANDLER_RANK="Alternate"
        ;;
    release)
        BUNDLE_ID="com.kawarimidoll.e05"
        DISPLAY_NAME="e05"
        BIN_SRC=".build/release/e05"
        URL_HANDLER_RANK="Owner"
        ;;
    *)
        echo "build_app.sh: unknown flavor '$FLAVOR' (expected dev|release)" >&2
        exit 1
        ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# The version string that lands in CFBundleShortVersionString.
# Dev builds always ride on a `dev-<sha>` string so every rebuild
# is distinct and traceable in the sidebar header without forcing
# a tag. Release builds prefer a tag *on HEAD* — a numeric CalVer
# (`2026.0614.1`) or SemVer, leading `v` stripped — so Launch
# Services can version-compare (Apple treats non-numeric as
# version 0, which would let `open` pick the wrong .app when
# releases share a bundle id family). An untagged HEAD is a
# dev/preview build, so it falls back to the same `dev-<sha>`
# string — non-numeric-leading, so Launch Services reads it as
# version 0 and it never shadows a real release — yielding a
# traceable e05-dev-<sha>.zip rather than a bogus 0.0.0.
# The integer commit count goes into CFBundleVersion regardless.
case "$FLAVOR" in
    dev)
        SHORT_VERSION="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        ;;
    release)
        if TAG="$(git describe --tags --exact-match 2>/dev/null)"; then
            # Extract the numeric core; a malformed tag falls to 0.0.0.
            SHORT_VERSION="$(echo "${TAG#v}" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)*' || true)"
            SHORT_VERSION="${SHORT_VERSION:-0.0.0}"
        else
            SHORT_VERSION="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
        fi
        ;;
esac
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Sanitize dynamic values so future git tags containing
# placeholder substitution metachars cannot break the rewrite.
# `-` is whitelisted for the `dev-<sha>` prefix (not a sed
# metachar, so it is safe in the replacement text). Constants
# (BUNDLE_ID, DISPLAY_NAME) are author-controlled and need no
# sanitization.
SHORT_VERSION="${SHORT_VERSION//[^A-Za-z0-9.-]/_}"
BUILD_NUMBER="${BUILD_NUMBER//[^0-9]/}"

APP_DIR="$REPO_ROOT/build/$FLAVOR/e05.app"
CONTENTS="$APP_DIR/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

sed \
    -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" \
    -e "s|__DISPLAY_NAME__|$DISPLAY_NAME|g" \
    -e "s|__SHORT_VERSION__|$SHORT_VERSION|g" \
    -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
    -e "s|__URL_HANDLER_RANK__|$URL_HANDLER_RANK|g" \
    "$REPO_ROOT/Resources/Info.plist.in" > "$CONTENTS/Info.plist"

if [[ ! -f "$BIN_SRC" ]]; then
    echo "build_app.sh: $BIN_SRC not found — run \`swift build\` first" >&2
    exit 1
fi
cp -f "$BIN_SRC" "$CONTENTS/MacOS/e05"

# CLI lands at Contents/Resources/bin/e05 so a user who PATH-injects
# the directory invokes it as `e05` rather than `e05cli`. Kept out of
# Contents/MacOS to avoid colliding with the main bundle executable.
# The shell shim alongside it shadows /usr/bin/open inside ghostty
# panes that inherit this dir on PATH.
CLI_SRC="${BIN_SRC%/*}/e05cli"
if [[ ! -f "$CLI_SRC" ]]; then
    echo "build_app.sh: $CLI_SRC not found — run \`swift build\` first" >&2
    exit 1
fi
mkdir -p "$CONTENTS/Resources/bin"
cp -f "$CLI_SRC" "$CONTENTS/Resources/bin/e05"
cp -f "$REPO_ROOT/Resources/bin/open" "$CONTENTS/Resources/bin/open"
# PATH-fix snippets sourced by the shell-integration (injected below)
# so the `open` shim shadows /usr/bin/open in e05 panes.
cp -f "$REPO_ROOT/Resources/bin/e05-integration.zsh" "$CONTENTS/Resources/bin/e05-integration.zsh"
cp -f "$REPO_ROOT/Resources/bin/e05-integration.bash" "$CONTENTS/Resources/bin/e05-integration.bash"
cp -f "$REPO_ROOT/Resources/bin/e05-integration.fish" "$CONTENTS/Resources/bin/e05-integration.fish"

# E05Lib's SwiftPM resources (the adblock JS runtimes), flattened into
# Contents/Resources rather than copied as the .bundle SwiftPM produces.
# `Bundle.module` looks for that bundle beside Bundle.main.bundleURL —
# the .app root — where codesign refuses to seal anything ("unsealed
# contents present in the bundle root"), so it cannot live where the
# generated accessor expects. BundledScript reads them from here
# instead; see its docstring for the whole picture.
RESOURCE_BUNDLE="${BIN_SRC%/*}/e05_E05Lib.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "build_app.sh: $RESOURCE_BUNDLE not found — run \`swift build\` first" >&2
    exit 1
fi
cp -f "$RESOURCE_BUNDLE"/*.js "$CONTENTS/Resources/"

# Sparkle (in-app updates). SwiftPM stages the framework beside the
# built binaries but does not embed it, so the bundle needs its own copy
# under Contents/Frameworks — that is where the @rpath reference baked
# into the executable resolves at launch. rsync --delete keeps it in
# sync across rebuilds the same way the ghostty resources are handled.
SPARKLE_SRC="${BIN_SRC%/*}/Sparkle.framework"
if [[ ! -d "$SPARKLE_SRC" ]]; then
    echo "build_app.sh: $SPARKLE_SRC not found — run \`swift build\` first" >&2
    exit 1
fi
mkdir -p "$CONTENTS/Frameworks"
rsync -a --delete "$SPARKLE_SRC/" "$CONTENTS/Frameworks/Sparkle.framework/"

# License texts for bundled copyleft dependencies (the GPLv3 ghostty /
# kitty shell-integration). GPLv3 requires the full license to ship
# with the work, so the .app carries it under Resources/licenses.
if [[ -d "$REPO_ROOT/Resources/licenses" ]]; then
    mkdir -p "$CONTENTS/Resources/licenses"
    # nullglob so an empty dir is a clean no-op instead of copying a
    # literal `*.txt`. A real copy failure still aborts the build (set
    # -e) rather than silently shipping a GPL bundle without its license.
    shopt -s nullglob
    license_texts=("$REPO_ROOT/Resources/licenses/"*.txt)
    shopt -u nullglob
    if (( ${#license_texts[@]} > 0 )); then
        cp -f "${license_texts[@]}" "$CONTENTS/Resources/licenses/"
    fi
fi

# Ghostty runtime resources (themes / shell-integration / terminfo),
# vendored under Resources/ and pinned via GHOSTTY_VERSION. Bundled so a
# release launched from Finder — with no GHOSTTY_RESOURCES_DIR inherited
# from a parent ghostty — still resolves built-in themes and the
# xterm-ghostty terminfo. GhosttyApp points GHOSTTY_RESOURCES_DIR at
# Contents/Resources/ghostty; terminfo sits beside it as
# Contents/Resources/terminfo (ghostty resolves terminfo adjacent to the
# resources dir). rsync --delete keeps the bundle in sync across rebuilds.
rsync -a --delete "$REPO_ROOT/Resources/ghostty/" "$CONTENTS/Resources/ghostty/"
rsync -a --delete "$REPO_ROOT/Resources/terminfo/" "$CONTENTS/Resources/terminfo/"

# Inject e05's PATH fix into the bundled shell-integration so every e05
# pane shell keeps the bundled bin dir ahead of /usr/bin (a prompt hook
# re-prepends post-path_helper, which a launch-time PATH prepend cannot
# survive in a login shell). This is what lets the `open` shim shadow
# /usr/bin/open with zero user setup, and the exported PATH covers child
# processes too. Applied to the bundle copy only — the repo's vendored
# integration stays pristine so a ghostty version bump's rsync diff is
# clean, and this re-applies every build so the bump can't silently drop
# it. The integration is Kitty-derived GPLv3; only this appended `source`
# line stays under GPL — the sourced e05-integration.* snippets are
# standalone e05 scripts (MIT). The grep guard prevents a double-inject.
# A missing target is a hard error, not a skip: these files are vendored
# in this repository, so their absence means a ghostty bump moved or
# renamed them — and a silent skip there takes the whole integration out
# without failing a build.
"$REPO_ROOT/scripts/inject_shell_integration.sh" "$CONTENTS"

# App icon: actool compiles the layered Icon Composer package
# (Resources/AppIcon.icon — icon.json + Assets/) into Assets.car (the
# macOS 26 layered icon carrying the Light / Dark / Tinted appearance
# variants) plus a legacy AppIcon.icns fallback for older macOS.
# PartialInfo.plist is requested only because actool warns when
# omitted; the two CFBundleIcon* keys it would emit are stable across
# SDK versions, so they are appended directly via PlistBuddy below.

# Localised ERR trap: anything inside the icon section that fails
# (mkdir / actool / cp) leaves a scoped breadcrumb instead of an
# opaque `set -e` abort.
trap 'echo "build_app.sh: icon section failed at line $LINENO" >&2' ERR

ICON_OUT="$REPO_ROOT/build/$FLAVOR/icon-out"
rm -rf "$ICON_OUT"
mkdir -p "$ICON_OUT"

ACTOOL_LOG="$ICON_OUT/actool.log"
xcrun actool \
    --compile "$ICON_OUT" \
    --app-icon AppIcon \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$ICON_OUT/PartialInfo.plist" \
    --warnings --notices --errors \
    "$REPO_ROOT/Resources/AppIcon.icon" >"$ACTOOL_LOG" 2>&1
# actool exits non-zero on most failures, but can also embed errors
# into its plist output while still exiting 0, so grep the log
# explicitly as a safety net.
if grep -q "com.apple.actool.errors" "$ACTOOL_LOG"; then
    echo "build_app.sh: actool reported errors:" >&2
    cat "$ACTOOL_LOG" >&2
    exit 1
fi

cp "$ICON_OUT/AppIcon.icns" "$ICON_OUT/Assets.car" "$CONTENTS/Resources/"
# Info.plist is regenerated from the template each build (sed block
# above), so PlistBuddy `Add` never collides with a previous run.
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleIconFile string AppIcon" \
    -c "Add :CFBundleIconName string AppIcon" \
    "$CONTENTS/Info.plist" >/dev/null

trap - ERR
# The codesign block below has its own explicit `|| { ... }` error
# handler that surfaces flavor-tagged failures, so the localized
# breadcrumb trap is no longer needed past this point.

# Ad-hoc sign so Bundle.main resolves and unified log Logger
# picks up the bundle id as subsystem. dev keeps Hardened Runtime
# off so unsigned WebKit helpers and bundled extensions load
# without per-component entitlements; release turns it on with
# the minimum entitlements needed by libghostty / WKWebView /
# .appex extensions to mirror what a distributed bundle uses.
#
# `E05_SIGN_IDENTITY` opts release builds into a real Developer ID
# identity. The default empty value keeps the ad-hoc path so an
# unsigned rebuild needs no extra setup. When set, the script
# adds Apple's Timestamp Server attestation that notarisation
# requires; identity-not-found surfaces through codesign's own
# error message. The dev flavor always ignores the variable so a
# deliberate `flavor=dev` stays unsigned-by-author even when the
# env happens to be exported.
SIGN_IDENTITY="${E05_SIGN_IDENTITY:-}"

# Every bundle nested in the app carries its own seal, applied
# inside-out so the outer signature covers settled contents. Sparkle
# accounts for most of them: four nested Mach-O payloads (two XPC
# services, the updater app, the Autoupdate tool) that arrive under the
# Sparkle project's own signature and are inspected individually during
# notarisation. Skipping any surfaces later as a notarisation Invalid
# with "binary is not signed with a valid Developer ID certificate".
sign_nested_bundles() {
    local fw="$CONTENTS/Frameworks/Sparkle.framework"
    local target
    for target in \
        "$fw/Versions/B/XPCServices/Downloader.xpc" \
        "$fw/Versions/B/XPCServices/Installer.xpc" \
        "$fw/Versions/B/Updater.app" \
        "$fw/Versions/B/Autoupdate" \
        "$fw"
    do
        codesign --force "$@" "$target" || {
            echo "build_app.sh: codesign failed for $target" >&2
            exit 1
        }
    done
}

case "$FLAVOR" in
    release)
        if [[ -n "$SIGN_IDENTITY" ]]; then
            # Inside-out signing: nested Mach-O binaries must carry a
            # Developer ID seal + Hardened Runtime + secure timestamp
            # before the bundle is sealed, otherwise notarisation
            # rejects them as ad-hoc and runtime-disabled. The `open`
            # shim alongside it is a bash script (not Mach-O) so
            # codesign would refuse it; we skip it deliberately.
            sign_nested_bundles --sign "$SIGN_IDENTITY" --options runtime --timestamp
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
                "$CONTENTS/Resources/bin/e05" || {
                echo "build_app.sh: codesign (release / Developer ID) failed for bundled CLI binary" >&2
                exit 1
            }
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
                --entitlements "$REPO_ROOT/Resources/e05.entitlements" \
                "$APP_DIR" || {
                echo "build_app.sh: codesign (release / Developer ID) failed at $APP_DIR — identity \"$SIGN_IDENTITY\" missing, invalid, or timestamp server unreachable" >&2
                exit 1
            }
        else
            sign_nested_bundles --sign - --options runtime
            codesign --force --sign - --options runtime \
                --entitlements "$REPO_ROOT/Resources/e05.entitlements" \
                "$APP_DIR" || {
                echo "build_app.sh: codesign (release / ad-hoc) failed at $APP_DIR" >&2
                exit 1
            }
        fi
        # Verify the seal is consistent across every nested
        # framework / helper bundle. An ad-hoc identity passes
        # --strict as long as the hash chain is intact, so a
        # failure here points at a packaging bug (missing helper
        # signature, embedded bundle drift) rather than identity
        # mismatch.
        codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | tail -5 || {
            echo "build_app.sh: codesign --verify failed for $APP_DIR" >&2
            exit 1
        }
        # Gatekeeper assessment is informational. Ad-hoc bundles
        # always report `source=No matching credential`; an
        # unnotarised Developer ID build reports
        # `source=Unnotarized Developer ID`; only a notarised +
        # stapled bundle reports `source=Notarized Developer ID`.
        # All three are expected at different stages of the flow,
        # so the assessment is logged rather than enforced here.
        spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 | tail -5 || true
        ;;
    *)
        sign_nested_bundles --sign -
        codesign --force --sign - "$APP_DIR" || {
            echo "build_app.sh: codesign failed for $FLAVOR bundle at $APP_DIR" >&2
            exit 1
        }
        ;;
esac

echo "$APP_DIR"
