#!/usr/bin/env bash
# Fetch the pinned Sparkle release into .sparkle/.
#
# Sparkle is consumed as a local binary target rather than a remote SwiftPM
# package, mirroring how GhosttyKit is handled. The reason is control over
# the download: SwiftPM's own artifact fetch has wedged silently in CI —
# "Downloading binary artifact" and then nothing, for over half an hour —
# with no retry or timeout to reach for. curl has both.
#
# Supplies two things from one archive:
#   .sparkle/Sparkle.xcframework  the framework Package.swift links against
#   .sparkle/bin/                 sign_update / generate_appcast / generate_keys
#
# Re-running is cheap: the fetch is skipped when .sparkle already holds the
# pinned version, so build scripts can call this unconditionally.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$REPO_ROOT/SPARKLE_VERSION"
DEST="$REPO_ROOT/.sparkle"

read_pin() {
    # `key=value` lines, ignoring comments and blanks.
    grep -E "^$1=" "$PIN_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]'
}

VERSION="$(read_pin version)"
EXPECTED_SHA="$(read_pin sha256)"
if [[ -z "$VERSION" || -z "$EXPECTED_SHA" ]]; then
    echo "fetch_sparkle.sh: version/sha256 missing from $PIN_FILE" >&2
    exit 1
fi

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$VERSION" ]]; then
    echo "fetch_sparkle.sh: Sparkle $VERSION already present"
    exit 0
fi

ARCHIVE="$(mktemp -t sparkle.XXXXXX)"
trap 'rm -f "$ARCHIVE"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-for-Swift-Package-Manager.zip"
echo "fetch_sparkle.sh: downloading Sparkle $VERSION"
# --max-time bounds the whole transfer so a stalled connection fails
# instead of hanging; --retry covers the transient failures that bound
# exposes. Both are what SwiftPM's fetch lacked.
curl -fsSL --retry 3 --retry-all-errors --max-time 300 -o "$ARCHIVE" "$URL"

ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "fetch_sparkle.sh: checksum mismatch for Sparkle $VERSION" >&2
    echo "  expected $EXPECTED_SHA" >&2
    echo "  actual   $ACTUAL_SHA" >&2
    exit 1
fi

# Only the framework and the tools; the archive also carries a demo app,
# symbols and licence texts that nothing here reads.
rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$ARCHIVE" 'Sparkle.xcframework/*' 'bin/*' -d "$DEST"
# The bundled tools arrive quarantined on some setups, which makes the
# first invocation fail with a Gatekeeper prompt rather than run.
xattr -cr "$DEST" 2>/dev/null || true
printf '%s' "$VERSION" > "$DEST/.version"

echo "fetch_sparkle.sh: Sparkle $VERSION ready in .sparkle"
