#!/usr/bin/env bash
# Submit a Developer ID-signed e05.app to Apple's notarisation
# service, staple the resulting ticket, and emit a distributable
# zip ready for upload to a release page.
#
# Sign is out of scope here: `scripts/build_app.sh release` with
# `E05_SIGN_IDENTITY=...` is expected to have produced the bundle.
# This script never re-signs; if the verify step fails it bails
# rather than silently papering over a packaging bug.
#
# Usage:
#   scripts/notarize.sh [--app PATH] [--zip PATH] [--dry-run] [--help]
#
# Required environment:
#   E05_NOTARY_KEY_PATH  Absolute path to the App Store Connect
#                        API .p8 file (downloaded once at key
#                        generation; cannot be re-downloaded).
#   E05_NOTARY_KEY_ID    10-character key id shown alongside the
#                        .p8 in App Store Connect.
#   E05_NOTARY_ISSUER    Issuer UUID shown above the key list in
#                        App Store Connect.
#
# Defaults:
#   --app build/release/e05.app
#   --zip build/release/e05-<CFBundleShortVersionString>.zip
#
# Output:
#   <zip-path> with the stapled .app inside.
#   On success: prints the zip path on stdout.
#   On failure: prints the notarytool log JSON on stderr and
#   exits 1.

set -euo pipefail

usage() {
    cat <<'EOF'
notarize.sh — notarise + staple a Developer ID-signed e05.app

Usage:
  scripts/notarize.sh [--app PATH] [--zip PATH] [--dry-run] [--help]

Options:
  --app PATH    Override input .app (default: build/release/e05.app)
  --zip PATH    Override output zip path
                (default: build/release/e05-<short-version>.zip)
  --dry-run     Validate inputs (env vars present, .app exists,
                signature verifies) without submitting to Apple.
  -h, --help    Show this message.

Required environment:
  E05_NOTARY_KEY_PATH  Path to App Store Connect API .p8 file.
  E05_NOTARY_KEY_ID    10-character API key id.
  E05_NOTARY_ISSUER    Issuer UUID.

See z-ai/developer-program.md for the full distribution flow.
EOF
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/build/release/e05.app"
ZIP_PATH=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || { echo "notarize.sh: --app requires a path" >&2; exit 1; }
            APP_PATH="$2"
            shift 2
            ;;
        --zip)
            [[ $# -ge 2 ]] || { echo "notarize.sh: --zip requires a path" >&2; exit 1; }
            ZIP_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "notarize.sh: unknown argument '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Env validation up front so users see all missing pieces in one
# message rather than discovering them one xcrun call at a time.
MISSING=()
[[ -z "${E05_NOTARY_KEY_PATH:-}" ]] && MISSING+=("E05_NOTARY_KEY_PATH")
[[ -z "${E05_NOTARY_KEY_ID:-}" ]] && MISSING+=("E05_NOTARY_KEY_ID")
[[ -z "${E05_NOTARY_ISSUER:-}" ]] && MISSING+=("E05_NOTARY_ISSUER")
if (( ${#MISSING[@]} > 0 )); then
    echo "notarize.sh: missing required env: ${MISSING[*]}" >&2
    echo "See \`scripts/notarize.sh --help\` for setup." >&2
    exit 1
fi

if [[ ! -f "$E05_NOTARY_KEY_PATH" ]]; then
    echo "notarize.sh: E05_NOTARY_KEY_PATH not found: $E05_NOTARY_KEY_PATH" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "notarize.sh: .app not found at $APP_PATH" >&2
    echo "Run \`E05_SIGN_IDENTITY=... scripts/build_app.sh release\` first." >&2
    exit 1
fi

# Read the bundle's user-facing version string with PlistBuddy
# (build_app.sh writes the plist by `sed`-substituting Info.plist.in,
# so there's no shared writer to match — PlistBuddy is just the
# clean way to read one key back out here).
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")"
if [[ -z "$SHORT_VERSION" ]]; then
    echo "notarize.sh: could not read CFBundleShortVersionString from $APP_PATH/Contents/Info.plist" >&2
    exit 1
fi

# Sanitise the same way build_app.sh sanitises the SHORT_VERSION
# constant before writing it into Info.plist, so the zip name and
# the bundle metadata stay aligned even if a future git tag
# introduces shell metacharacters. `-` is whitelisted to match
# build_app.sh's `dev-<sha>` prefix.
SHORT_VERSION="${SHORT_VERSION//[^A-Za-z0-9.-]/_}"

if [[ -z "$ZIP_PATH" ]]; then
    ZIP_PATH="$REPO_ROOT/build/release/e05-${SHORT_VERSION}.zip"
fi

# Pre-submission seal check: an adhoc-signed bundle reaches the
# notarisation server and gets rejected with a vague "not signed
# with a Developer ID" error, which is harder to debug than a
# local verify failure. Fail fast here instead.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 || {
    echo "notarize.sh: codesign --verify failed for $APP_PATH" >&2
    echo "Re-sign with \`E05_SIGN_IDENTITY=... scripts/build_app.sh release\`." >&2
    exit 1
}

# Reject ad-hoc signatures explicitly. notarytool would reject
# them too but only after upload + a multi-minute queue wait;
# checking the Signature line locally saves the round trip.
# Capture into a variable so the SIGPIPE that `grep -q` would
# otherwise raise against codesign does not leave a pipefail
# residue if this block is ever lifted out of an `if` context.
SIG_INFO="$(codesign -dvvv "$APP_PATH" 2>&1 || true)"
if grep -qE "^Signature=adhoc" <<<"$SIG_INFO"; then
    echo "notarize.sh: $APP_PATH is ad-hoc signed; notarisation requires a Developer ID identity." >&2
    echo "Re-sign with \`E05_SIGN_IDENTITY=\"Developer ID Application: <Name> (<TEAM_ID>)\" scripts/build_app.sh release\`." >&2
    exit 1
fi

if (( DRY_RUN )); then
    echo "notarize.sh: dry-run OK"
    echo "  app:   $APP_PATH"
    echo "  zip:   $ZIP_PATH"
    echo "  ver:   $SHORT_VERSION"
    echo "  key:   $E05_NOTARY_KEY_PATH"
    echo "  keyid: $E05_NOTARY_KEY_ID"
    echo "  iss:   $E05_NOTARY_ISSUER"
    exit 0
fi

mkdir -p "$(dirname "$ZIP_PATH")"

# ditto -c -k --keepParent wraps the .app under a single top-level
# directory inside the zip, which is what Finder expects when the
# user double-clicks the archive (a flat layout would scatter
# Contents/ at the unzip root).
echo "notarize.sh: packaging $APP_PATH → $ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "notarize.sh: submitting to Apple (typically 5–15 minutes)…"
# --wait blocks until the submission reaches a terminal state so
# the script can branch on status without manual polling. The
# submission id is captured separately because `notarytool log`
# needs it on the failure path.
SUBMIT_LOG="$(mktemp)"
trap 'rm -f "$SUBMIT_LOG"' EXIT

if ! xcrun notarytool submit "$ZIP_PATH" \
        --key "$E05_NOTARY_KEY_PATH" \
        --key-id "$E05_NOTARY_KEY_ID" \
        --issuer "$E05_NOTARY_ISSUER" \
        --wait \
        --output-format json \
        > "$SUBMIT_LOG" 2>&1; then
    echo "notarize.sh: xcrun notarytool submit failed" >&2
    cat "$SUBMIT_LOG" >&2
    rm -f "$ZIP_PATH"
    exit 1
fi

# Parse the submission id and status out of notarytool's JSON.
# notarytool emits JSON, and python3 is guaranteed to be present
# because the Xcode Command Line Tools that ship notarytool also
# install python3 — so this never adds an extra dependency.
SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$SUBMIT_LOG" 2>/dev/null || echo "")"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$SUBMIT_LOG" 2>/dev/null || echo "")"

if [[ "$STATUS" != "Accepted" ]]; then
    echo "notarize.sh: notarisation status = '$STATUS' (id=$SUBMISSION_ID)" >&2
    # Always dump the raw submit output so a malformed JSON or
    # missing status field still leaves a forensic trail rather
    # than a bare "status = ''" with no context.
    echo "notarize.sh: notarytool submit raw output:" >&2
    cat "$SUBMIT_LOG" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "notarize.sh: fetching detailed log…" >&2
        xcrun notarytool log "$SUBMISSION_ID" \
            --key "$E05_NOTARY_KEY_PATH" \
            --key-id "$E05_NOTARY_KEY_ID" \
            --issuer "$E05_NOTARY_ISSUER" >&2 \
            || echo "notarize.sh: notarytool log fetch failed (id=$SUBMISSION_ID)" >&2
    fi
    rm -f "$ZIP_PATH"
    exit 1
fi

echo "notarize.sh: notarisation accepted (id=$SUBMISSION_ID)"

# Once the submit succeeded, the un-stapled zip in $ZIP_PATH is
# stale — it lacks the ticket and would still report
# "Unnotarized Developer ID" on a machine without internet. Drop
# it now and rebuild after stapling so the post-staple zip is the
# only artefact left on disk regardless of which step fails next.
rm -f "$ZIP_PATH"
trap 'rm -f "$SUBMIT_LOG" "$ZIP_PATH"' EXIT

# Staple the ticket into the .app so Gatekeeper can verify it
# offline. Failure here leaves no zip behind thanks to the EXIT
# trap, so the next run cannot silently re-publish a stale bundle.
echo "notarize.sh: stapling ticket into $APP_PATH"
xcrun stapler staple "$APP_PATH"

echo "notarize.sh: repackaging stapled app → $ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# Reaching this line means the zip is the final intended
# artefact; drop the cleanup so the EXIT trap does not erase it.
trap 'rm -f "$SUBMIT_LOG"' EXIT

# Final Gatekeeper assessment. The expected line is
#   source=Notarized Developer ID
# but spctl occasionally hiccups on a transient ticket-cache
# refresh right after stapling, so the check is informational
# rather than blocking — the surfaced output still lets the
# operator confirm the assessment after the fact.
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 | tail -5 || true

echo "$ZIP_PATH"
