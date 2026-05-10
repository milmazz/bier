#!/usr/bin/env bash
# role-guard.sh — enforce the file-ownership matrix from docs/AGENT_PLAN.md §4.
#
# Determines the agent role from the AGENT_ROLE env var (preferred) or the
# current branch name (fallback), then rejects any file change whose path
# is outside that role's writable globs.
#
# Exit codes:
#   0  — diff is within role's globs
#   1  — diff includes paths outside role's globs (lists them)
#   2  — usage / configuration error
#
# Used by .githooks/pre-commit (developer's local check) and the
# `role-guard` job in .github/workflows/ci.yml (authoritative check).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: role-guard.sh [BASE_REF]

Determines role from $AGENT_ROLE or branch name, then verifies that every
file touched between BASE_REF and HEAD belongs to the role's writable
globs. BASE_REF defaults to "origin/main"; in a pre-commit context the
caller should pass "" to fall back to the staged index.

Branch-name → role mapping:
  spec/*       researcher
  test/*       tester
  feat/*       developer
  chore/*, docs/*, phase-*/*, main, master  → orchestrator
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

role="${AGENT_ROLE:-}"
branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)}"

if [[ -z "$role" ]]; then
  case "$branch" in
    spec/*|researcher/*)               role="researcher" ;;
    test/*|tester/*)                   role="tester" ;;
    feat/*|developer/*)                role="developer" ;;
    chore/*|docs/*|phase-*/*|main|master|HEAD) role="orchestrator" ;;
    *) role="orchestrator" ;;
  esac
fi

# Allowed-path regex per role. Mirrors the matrix in docs/AGENT_PLAN.md §4.
# CHANGELOG.md is RW for every role (one Unreleased entry per PR).
case "$role" in
  researcher)
    allowed='^(spec/|CHANGELOG\.md$)'
    ;;
  tester)
    allowed='^(test/|priv/repo/|CHANGELOG\.md$|mix\.exs$|mix\.lock$)'
    ;;
  developer)
    allowed='^(lib/|CHANGELOG\.md$|mix\.exs$|mix\.lock$)'
    ;;
  orchestrator)
    allowed='.*'
    ;;
  *)
    echo "role-guard: unknown role '$role'" >&2
    exit 2
    ;;
esac

base="${1-origin/main}"

if [[ -n "$base" ]] && git rev-parse --verify --quiet "$base" >/dev/null; then
  files=$(git diff --name-only "$base"...HEAD)
else
  # Pre-commit fallback: check the staged index against HEAD.
  files=$(git diff --name-only --cached)
fi

bad=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if ! [[ "$f" =~ $allowed ]]; then
    bad+=("$f")
  fi
done <<< "$files"

if [[ ${#bad[@]} -gt 0 ]]; then
  echo "role-guard: role '$role' (branch '$branch') may not modify:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  echo "" >&2
  echo "Allowed paths for '$role': $allowed" >&2
  echo "" >&2
  echo "Either rebrand the branch (e.g. feat/<slice> for a Developer)," >&2
  echo "set AGENT_ROLE=<role> if you really are that agent, or move the" >&2
  echo "out-of-scope work into the right role's PR." >&2
  exit 1
fi

count=$(echo "$files" | grep -c . || true)
echo "role-guard: ok (role=$role, branch=$branch, $count files in scope)"
