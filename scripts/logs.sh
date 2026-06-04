#!/usr/bin/env bash
# Tail e05's own os.Logger output (dev and release share the same
# fixed subsystem; see Sources/Lib/Utility/LogSubsystem.swift).
#
# The default `log stream` level is notice, so info/debug stay hidden
# without the --level debug below. Interpolated strings are redacted
# as <private> unless logged with `\(value, privacy: .public)`.
#
# An optional first argument filters further and is AND-combined with
# the subsystem filter (one --predicate is built here, since `log
# stream` does not document how it merges multiple --predicate flags).
# A value carrying a comparison operator (=, <, >, !), braces, or a
# string operator (CONTAINS / BEGINSWITH / ENDSWITH / LIKE / MATCHES) is
# used verbatim; anything else is matched as a case-insensitive message
# substring, so the common "show lines mentioning X" case needs no
# NSPredicate syntax. Short logical words (AND / OR / NOT / IN) are not
# treated as operators on their own — real predicates carry a
# comparison or string operator too — so a phrase like "in flight" stays
# a substring. To search for text that contains an operator character,
# write the full `eventMessage CONTAINS "..."`. Remaining args pass
# through:
#   scripts/logs.sh                                          # all e05 logs
#   scripts/logs.sh install                                  # messages containing "install"
#   scripts/logs.sh 'category == "Focus"'                    # one category
#   scripts/logs.sh 'category != "NativeMessaging" AND category != "Extensions"'  # drop noise
#   scripts/logs.sh --style json                             # forward log flags

set -euo pipefail

predicate='subsystem == "com.kawarimidoll.e05"'
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  if printf '%s' "$1" | grep -Eqi '[=<>!{}]|(^| )(contains|beginswith|endswith|like|matches)( |$)'; then
    # Looks like a predicate fragment — AND it in verbatim.
    predicate="$predicate AND ($1)"
  else
    # Bare word — match it as a case-insensitive message substring so
    # `logs.sh install` works without hand-writing an NSPredicate. Escape
    # any embedded double quote so it can't unbalance the predicate's
    # string literal.
    escaped="${1//\"/\\\"}"
    predicate="$predicate AND (eventMessage CONTAINS[c] \"$escaped\")"
  fi
  shift
fi

exec log stream \
  --predicate "$predicate" \
  --level debug \
  --style compact \
  "$@"
