#!/usr/bin/env bash
# Bump the pinned ghostty commit in one step: rebuild GhosttyKit and
# re-vendor the runtime resources (themes / shell-integration / terminfo)
# from the SAME commit, then write both GHOSTTY_VERSION and the
# Resources/ghostty/.source-commit stamp so the binary and resources
# can't silently drift apart (GhosttyResourcesTests enforces the match).
#
# This automates the manual flow in CONTRIBUTING.md ("Building
# GhosttyKit"). It does NOT install the Metal Toolchain / CoreSimulator
# prerequisites — do that once by hand if the zig build's `Ld ghostty`
# step fails (see CONTRIBUTING).
#
# Usage:
#   scripts/bump_ghostty.sh --ghostty <path-to-ghostty-checkout> [<ref>]
#
#   <ref> defaults to origin/main. Pass a SHA/tag to pin a specific one.
#   ZIG=<path> overrides the zig binary (default: Homebrew's zig@0.15 keg).

set -euo pipefail

E05_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"

GHOSTTY_DIR=""
REF="origin/main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ghostty)
      GHOSTTY_DIR="${2:-}"
      shift 2
      ;;
    -h | --help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      REF="$1"
      shift
      ;;
  esac
done

if [[ -z "$GHOSTTY_DIR" ]]; then
  echo "error: --ghostty <path-to-ghostty-checkout> is required" >&2
  exit 2
fi
if [[ ! -d "$GHOSTTY_DIR/.git" ]]; then
  echo "error: $GHOSTTY_DIR is not a git checkout" >&2
  exit 2
fi
if [[ ! -x "$ZIG" ]]; then
  echo "error: zig not found at $ZIG (set ZIG=<path>)" >&2
  exit 2
fi

echo "[bump] fetching ghostty and checking out $REF"
git -C "$GHOSTTY_DIR" fetch --quiet origin
git -C "$GHOSTTY_DIR" checkout --quiet "$REF"
SHA="$(git -C "$GHOSTTY_DIR" rev-parse HEAD)"
echo "[bump] resolved $REF -> $SHA"

echo "[bump] applying e05 patches"
git -C "$GHOSTTY_DIR" apply "$E05_ROOT"/patches/*.patch

echo "[bump] building GhosttyKit (this needs the Metal Toolchain; see CONTRIBUTING)"
(
  cd "$GHOSTTY_DIR"
  "$ZIG" build \
    -Doptimize=ReleaseFast \
    -Dapp-runtime=none \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-exe=false \
    -Dsentry=false
)

echo "[bump] vendoring xcframework + runtime resources"
xattr -cr "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" || true
rm -rf "$E05_ROOT/GhosttyKit.xcframework"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$E05_ROOT/GhosttyKit.xcframework"
rsync -a --delete "$GHOSTTY_DIR/zig-out/share/ghostty/themes/" \
  "$E05_ROOT/Resources/ghostty/themes/"
rsync -a --delete "$GHOSTTY_DIR/zig-out/share/ghostty/shell-integration/" \
  "$E05_ROOT/Resources/ghostty/shell-integration/"
rsync -a --delete "$GHOSTTY_DIR/zig-out/share/terminfo/" \
  "$E05_ROOT/Resources/terminfo/"

echo "[bump] pinning $SHA in GHOSTTY_VERSION + .source-commit"
VERSION_FILE="$E05_ROOT/GHOSTTY_VERSION"
# Preserve the comment header, replace only the pinned SHA line.
{
  grep -E '^[[:space:]]*(#|$)' "$VERSION_FILE"
  echo "$SHA"
} >"$VERSION_FILE.tmp"
mv "$VERSION_FILE.tmp" "$VERSION_FILE"
echo "$SHA" >"$E05_ROOT/Resources/ghostty/.source-commit"

echo "[bump] done. Rebuild the app (./scripts/dev.sh) and run: swift test --disable-sandbox"
echo "[bump] the patches were applied to $GHOSTTY_DIR; 'git -C $GHOSTTY_DIR apply -R patches/*.patch' to revert if needed"
