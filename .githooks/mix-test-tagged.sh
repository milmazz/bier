#!/usr/bin/env bash
# mix-test-tagged.sh — run `mix test --only <tag>` and tolerate empty matches.
#
# Elixir 1.19's `mix test --only <tag>` exits 1 with the message
# "The --only option was given to "mix test" but no test was executed"
# when no test in the suite carries that tag. That is the right
# default for a mature suite (it catches typos in tag names) but it
# breaks Phase 0 / 1 CI for tags whose tests do not exist yet
# (`:conformance`, `:property`).
#
# This wrapper preserves any real failure but treats the
# "no test was executed" path as success.
#
# Usage: bash .githooks/mix-test-tagged.sh <tag> [extra mix test args...]

set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: mix-test-tagged.sh <tag> [extra mix test args...]" >&2
  exit 2
fi

tag="$1"
shift

set +e
output=$(mix test --only "$tag" "$@" 2>&1)
rc=$?
set -e

echo "$output"

if [[ $rc -eq 1 ]] && echo "$output" | grep -q "no test was executed"; then
  echo "mix-test-tagged: no :$tag tests in scope yet — treating as pass"
  exit 0
fi

exit $rc
