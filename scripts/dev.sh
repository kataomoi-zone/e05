#!/usr/bin/env bash
# Fast dev iteration: swift build → assemble dev .app → launch.
#
# Runs the binary directly out of the bundle so stderr stays
# attached to the terminal and bundle-identity APIs resolve.
# os.Logger uses a fixed subsystem (com.kawarimidoll.e05, see
# LogSubsystem); tail it with scripts/logs.sh.
# Extra args are forwarded to the e05 binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

swift build
scripts/build_app.sh dev > /dev/null
exec build/dev/e05.app/Contents/MacOS/e05 "$@"
