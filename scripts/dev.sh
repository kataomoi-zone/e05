#!/usr/bin/env bash
# Fast dev iteration: swift build → assemble dev .app → launch.
#
# Runs the binary directly out of the bundle so stderr stays
# attached to the terminal and bundle-identity APIs resolve.
# The app's own os.Logger output is streamed into the same output
# alongside it, so `scripts/dev.sh &> file` captures everything the
# run says in one place.
# Extra args are forwarded to the e05 binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

# A release e05 logs under the same subsystem, so keep only lines from
# this bundle's processes. Started before the build so the stream is
# attached by the time the app logs its first line.
scripts/logs.sh "processImagePath BEGINSWITH \"$REPO_ROOT/build/dev/\"" &
log_stream=$!
# The pause lets entries logd is still delivering reach the stream.
trap 'sleep 1; kill "$log_stream" 2>/dev/null || true' EXIT

swift build
scripts/build_app.sh dev > /dev/null

# A child rather than exec, so the stream stops with the app. A
# background job ignores SIGINT, so Ctrl-C and `kill` on this script
# are forwarded to the app explicitly.
build/dev/e05.app/Contents/MacOS/e05 "$@" &
app=$!
trap 'kill "$app" 2>/dev/null || true' INT TERM
wait "$app"
