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
        BUNDLE_ID="org.kawarimidoll.e05.debug"
        DISPLAY_NAME="e05[DEV]"
        BIN_SRC=".build/debug/e05"
        URL_HANDLER_RANK="Alternate"
        ;;
    release)
        BUNDLE_ID="org.kawarimidoll.e05"
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

# Apple requires CFBundleShortVersionString to look like N[.N[.N]]
# (Launch Services treats non-numeric as version 0, which makes
# `open` pick the wrong .app when multiple flavors share a bundle
# id family). Extract the SemVer prefix from `git describe`; fall
# back to 0.0.0 when no tag exists yet. The integer commit count
# goes into CFBundleVersion separately.
RAW_VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)"
# Require at least N.N so an all-digit short SHA (git falls back
# to a bare hash when there are no tags, ~4% are all decimal)
# does not get mistaken for a version. Fall back to 0.0.0 then.
SHORT_VERSION="$(echo "${RAW_VERSION#v}" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)*' || true)"
SHORT_VERSION="${SHORT_VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

# Sanitize dynamic values so future git tags containing
# placeholder substitution metachars cannot break the rewrite.
# Constants (BUNDLE_ID, DISPLAY_NAME) are author-controlled
# and need no sanitization.
SHORT_VERSION="${SHORT_VERSION//[^A-Za-z0-9.]/_}"
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

# App icon: rsvg-convert renders icon.svg into the seven PNG sizes
# the macOS .appiconset format references, then actool compiles them
# into AppIcon.icns + Assets.car. PartialInfo.plist is requested only
# because actool warns when omitted; the two CFBundleIcon* keys it
# would emit are stable across SDK versions, so they are appended
# directly via PlistBuddy below. The staging dir lives under build/
# so the source asset catalog stays free of generated PNGs.
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "build_app.sh: rsvg-convert not found (install via \`brew install librsvg\`)" >&2
    exit 1
fi

# Localised ERR trap: anything inside the icon section that fails
# (rsvg-convert / cp / mkdir / actool) leaves a scoped breadcrumb
# instead of an opaque `set -e` abort.
trap 'echo "build_app.sh: icon section failed at line $LINENO" >&2' ERR

ICON_STAGING="$REPO_ROOT/build/$FLAVOR/icon-staging"
ICON_OUT="$REPO_ROOT/build/$FLAVOR/icon-out"
rm -rf "$ICON_STAGING" "$ICON_OUT"
mkdir -p "$ICON_STAGING/Assets.xcassets/AppIcon.appiconset" "$ICON_OUT"
cp "$REPO_ROOT/Resources/Assets.xcassets/Contents.json" \
    "$ICON_STAGING/Assets.xcassets/Contents.json"
cp "$REPO_ROOT/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" \
    "$ICON_STAGING/Assets.xcassets/AppIcon.appiconset/Contents.json"
for size in 16 32 64 128 256 512 1024; do
    rsvg-convert -w "$size" -h "$size" \
        "$REPO_ROOT/Resources/icon.svg" \
        -o "$ICON_STAGING/Assets.xcassets/AppIcon.appiconset/icon_${size}x${size}.png"
done

ACTOOL_LOG="$ICON_OUT/actool.log"
xcrun actool \
    --compile "$ICON_OUT" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$ICON_OUT/PartialInfo.plist" \
    --warnings --notices --errors \
    "$ICON_STAGING/Assets.xcassets" >"$ACTOOL_LOG" 2>&1
# actool returns 0 even when it embeds errors into its plist output,
# so grep the log explicitly to surface them.
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
case "$FLAVOR" in
    release)
        codesign --force --sign - --options runtime \
            --entitlements "$REPO_ROOT/Resources/e05.entitlements" \
            "$APP_DIR" || {
            echo "build_app.sh: codesign (release) failed at $APP_DIR" >&2
            exit 1
        }
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
        # Gatekeeper assessment is informational: ad-hoc bundles
        # without notarization are always rejected, so the output
        # confirms the rejection reason matches expectations
        # (`source=No matching credential`, etc.) rather than
        # surfacing a blocking error.
        spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 | tail -5 || true
        ;;
    *)
        codesign --force --sign - "$APP_DIR" || {
            echo "build_app.sh: codesign failed for $FLAVOR bundle at $APP_DIR" >&2
            exit 1
        }
        ;;
esac

echo "$APP_DIR"
