#!/usr/bin/env bash
# changelog-check.sh — enforce CHANGELOG.md "[Unreleased]" gate from §8 #11.
#
# Verifies that every PR adds at least one substantive line under
# `## [Unreleased]` in CHANGELOG.md. Exempted only when SKIP=true is
# passed in the environment (CI sets this from the `changelog:skip` PR
# label, per docs/AGENT_PLAN.md §8 #11).

set -euo pipefail

if [[ "${SKIP:-false}" == "true" ]]; then
  echo "changelog-check: skipped via 'changelog:skip' label"
  exit 0
fi

base="${1:-origin/main}"

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
  echo "changelog-check: cannot resolve base ref '$base' — skipping" >&2
  exit 0
fi

# Extract the [Unreleased] section from a given ref.
extract_unreleased() {
  local ref="$1"
  git show "$ref:CHANGELOG.md" 2>/dev/null \
    | awk '
        /^## \[Unreleased\]/ { flag = 1; next }
        /^## \[/             { flag = 0 }
        flag                 { print }
      '
}

old=$(extract_unreleased "$base" || true)
new=$(extract_unreleased "HEAD" || true)

if [[ -z "$new" ]]; then
  echo "changelog-check: CHANGELOG.md is missing or has no [Unreleased] section" >&2
  exit 1
fi

# Strip blank lines and pure heading lines (### Added etc.) so a PR that
# only added section scaffolding without any actual entry is rejected.
strip_scaffold() {
  grep -v -E '^\s*$' | grep -v -E '^\s*###? '
}

old_body=$(echo "$old" | strip_scaffold || true)
new_body=$(echo "$new" | strip_scaffold || true)

if [[ "$old_body" == "$new_body" ]]; then
  echo "changelog-check: no new entry under ## [Unreleased]" >&2
  echo "" >&2
  echo "Add a bullet describing your change (Keep a Changelog 1.1.0 sections" >&2
  echo "are: Added, Changed, Deprecated, Removed, Fixed, Security, plus the" >&2
  echo "Bier-specific 'Spec' and 'Tests' sections), or apply the" >&2
  echo "'changelog:skip' label if the PR has no user-visible effect." >&2
  exit 1
fi

echo "changelog-check: ok"
