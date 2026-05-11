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

# Ad-hoc sign so Bundle.main resolves and unified log Logger
# picks up the bundle id as subsystem. Hardened runtime is
# intentionally off in dev so unsigned WebKit helpers and
# bundled extensions load without per-component entitlements.
codesign --force --sign - "$APP_DIR" || {
    echo "build_app.sh: codesign failed for $FLAVOR bundle at $APP_DIR" >&2
    exit 1
}

echo "$APP_DIR"
