#!/usr/bin/env bash
# Emit a signed Sparkle appcast for one release zip.
#
# The feed carries a single item: Sparkle only needs the newest version
# to decide whether an update exists, and serving the file as a release
# asset (`releases/latest/download/appcast.xml`) means each release
# publishes its own feed anyway. Version history would only matter for
# showing the notes of versions a user skipped past.
#
# Signing uses Sparkle's own `sign_update`, which SwiftPM already
# unpacked under .build/artifacts as part of resolving the dependency —
# no separate download, and the checksum SwiftPM verified covers it.
#
# Usage:
#   scripts/sign_appcast.sh <zip> <app-bundle> <download-url> [ed-key-file]
#
# The EdDSA key comes from the login keychain unless <ed-key-file> is
# given (which is how CI passes the secret without a keychain).
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "usage: $0 <zip> <app-bundle> <download-url> [ed-key-file]" >&2
    exit 2
fi

ZIP="$1"
APP="$2"
URL="$3"
KEY_FILE="${4:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"

for required in "$ZIP" "$APP" "$SIGN_UPDATE"; do
    if [[ ! -e "$required" ]]; then
        echo "sign_appcast.sh: $required not found" >&2
        [[ "$required" == "$SIGN_UPDATE" ]] && echo "  (run \`swift build\` first)" >&2
        exit 1
    fi
done

plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"
}

# Sparkle compares `sparkle:version` (CFBundleVersion) to decide what is
# newer and shows `shortVersionString` to the user — the same split the
# bundle already makes: a monotonic commit count against the CalVer tag.
SHORT_VERSION="$(plist CFBundleShortVersionString)"
BUILD_VERSION="$(plist CFBundleVersion)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"

# `sign_update` prints the enclosure attributes verbatim:
#   sparkle:edSignature="…" length="…"
if [[ -n "$KEY_FILE" ]]; then
    SIGNATURE_ATTRS="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$ZIP")"
else
    SIGNATURE_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
fi

# RFC 822, in C locale so the day/month names stay ASCII regardless of
# the machine's locale. BSD date has no -R.
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>e05</title>
    <link>${URL%%/releases/*}</link>
    <description>Updates for e05</description>
    <language>en</language>
    <item>
      <title>$SHORT_VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE_ATTRS />
    </item>
  </channel>
</rss>
XML
