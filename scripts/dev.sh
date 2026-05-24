#!/usr/bin/env bash
# Fast dev iteration: swift build → assemble dev .app → launch.
#
# Runs the binary directly out of the bundle so stderr is
# attached to the terminal and unified log Logger picks up
# the dev bundle id (com.kawarimidoll.e05.debug) as subsystem.
# Extra args are forwarded to the e05 binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

swift build
scripts/build_app.sh dev > /dev/null
exec build/dev/e05.app/Contents/MacOS/e05 "$@"
