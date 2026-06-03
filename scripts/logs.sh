#!/usr/bin/env bash
# Tail e05's own os.Logger output (dev and release share the same
# fixed subsystem; see Sources/Lib/Utility/LogSubsystem.swift).
#
# The default `log stream` level is notice, so info/debug stay hidden
# without the --level debug below. Interpolated strings are redacted
# as <private> unless logged with `\(value, privacy: .public)`.
#
# An optional first argument is AND-combined with the subsystem filter
# (one --predicate is built here, since `log stream` does not document
# how it merges multiple --predicate flags). Remaining args pass through:
#   scripts/logs.sh                                          # all e05 logs
#   scripts/logs.sh 'category == "Focus"'                    # one category
#   scripts/logs.sh 'category != "NativeMessaging" AND category != "Extensions"'  # drop noise
#   scripts/logs.sh --style json                             # forward log flags

set -euo pipefail

predicate='subsystem == "com.kawarimidoll.e05"'
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  predicate="$predicate AND ($1)"
  shift
fi

exec log stream \
  --predicate "$predicate" \
  --level debug \
  --style compact \
  "$@"
