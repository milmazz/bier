#!/usr/bin/env bash
# role-guard.sh — enforce the file-ownership matrix and trailer audit
# from docs/AGENT_PLAN.md §4.1, §4.2, §4.3.
#
# Role resolution priority (highest first, per §4.1):
#   1. PR label    — PR_LABELS env (newline- or comma-separated label
#                    names; first `role:<role>` wins). Set by CI from
#                    github.event.pull_request.labels.
#   2. Branch prefix — research/, test/, dev/<slice>/, review/,
#                      chore/, audit/.
#   3. Commit trailer — `X-Bier-Role: <role>` on the most recent
#                       commit between BASE_REF and HEAD.
#
# Local override: AGENT_ROLE env wins over the three signals when
# PR_LABELS is empty (i.e. not in a CI PR context). This is for
# subagent wrappers that know their role authoritatively.
#
# Checks performed:
#   - Glob check: every changed file in BASE_REF..HEAD (or the staged
#     index in a pre-commit context) must match the role's writable
#     globs (§4.2).
#   - Trailer audit: at least one commit between BASE_REF and HEAD
#     must carry `X-Bier-Role: <role>` matching the resolved role.
#     Skipped only when there are no commits yet to audit (fresh
#     branch in pre-commit, before the first commit lands).
#
# Exit codes:
#   0  — OK
#   1  — glob check failed (lists offending files)
#   2  — role could not be determined / configuration error
#   3  — trailer audit failed (lists commits missing the trailer)
#
# Used by .githooks/pre-commit (developer's local check) and the
# `role-guard` job in .github/workflows/ci.yml (authoritative check).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: role-guard.sh [BASE_REF]

Resolves the agent role (PR label → branch prefix → commit trailer,
with AGENT_ROLE as a local override) and enforces:

  1. File-glob check    — diff vs. BASE_REF must lie inside the role's
                          writable globs.
  2. Trailer audit      — at least one commit on the branch carries
                          `X-Bier-Role: <role>`.

BASE_REF defaults to "origin/main". Pass "" to fall back to the
staged index (pre-commit context).

Branch-prefix → role mapping (§4.1):
  research/*    researcher
  test/*        tester
  dev/*         developer
  review/*      reviewer
  audit/*       auditor
  chore/*, docs/*, phase-*/*, main, master  → orchestrator

PR labels (§4.1): role:researcher, role:tester, role:developer,
                  role:reviewer, role:orchestrator, role:auditor.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

base="${1-origin/main}"

###############################################################################
# 1. Resolve role
###############################################################################

valid_roles_re='^(researcher|tester|developer|reviewer|orchestrator|auditor)$'

role_from_labels() {
  local labels="${PR_LABELS:-}"
  [[ -z "$labels" ]] && return 1
  # Normalize separators: commas → newlines, then iterate.
  while IFS= read -r label; do
    label="${label//[[:space:]]/}"
    if [[ "$label" =~ ^role:(.+)$ ]]; then
      local r="${BASH_REMATCH[1]}"
      if [[ "$r" =~ $valid_roles_re ]]; then
        echo "$r"
        return 0
      fi
    fi
  done < <(printf '%s' "$labels" | tr ',' '\n')
  return 1
}

role_from_branch() {
  local branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)}"
  case "$branch" in
    research/*)                                role="researcher" ;;
    test/*)                                    role="tester" ;;
    dev/*)                                     role="developer" ;;
    review/*)                                  role="reviewer" ;;
    audit/*)                                   role="auditor" ;;
    chore/*|docs/*|phase-*/*|main|master|HEAD) role="orchestrator" ;;
    *)                                         role="orchestrator" ;;
  esac
  echo "$role"
}

role_from_trailer() {
  # Most recent commit's X-Bier-Role trailer between base..HEAD.
  if [[ -n "$base" ]] && git rev-parse --verify --quiet "$base" >/dev/null; then
    local trailer
    trailer=$(git log "$base"..HEAD \
      --format='%(trailers:key=X-Bier-Role,valueonly,separator=%x09)' 2>/dev/null \
      | tr '\t' '\n' \
      | awk 'NF { print; exit }')
    if [[ -n "$trailer" && "$trailer" =~ $valid_roles_re ]]; then
      echo "$trailer"
      return 0
    fi
  fi
  return 1
}

# Priority: PR_LABELS > branch prefix > commit trailer.
# AGENT_ROLE overrides all three only if PR_LABELS is empty (local).
role=""
if [[ -n "${PR_LABELS:-}" ]]; then
  if role=$(role_from_labels); then
    role_source="pr-label"
  fi
elif [[ -n "${AGENT_ROLE:-}" ]]; then
  if [[ "${AGENT_ROLE}" =~ $valid_roles_re ]]; then
    role="$AGENT_ROLE"
    role_source="agent-role-env"
  else
    echo "role-guard: AGENT_ROLE='$AGENT_ROLE' is not a valid role" >&2
    exit 2
  fi
fi

if [[ -z "$role" ]]; then
  role=$(role_from_branch)
  role_source="branch-prefix"
  # If branch resolution defaulted to orchestrator on an unknown
  # prefix, give the trailer a chance to override.
  branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)}"
  case "$branch" in
    research/*|test/*|dev/*|review/*|audit/*|chore/*|docs/*|phase-*/*|main|master|HEAD) ;;
    *)
      if trailer_role=$(role_from_trailer); then
        role="$trailer_role"
        role_source="commit-trailer"
      fi
      ;;
  esac
fi

if [[ -z "$role" ]]; then
  echo "role-guard: could not determine role (no PR_LABELS, branch prefix, or X-Bier-Role trailer matched)" >&2
  exit 2
fi

branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo)}"

###############################################################################
# 2. Glob check
###############################################################################

# Allowed-path regex per role. Mirrors the matrix in docs/AGENT_PLAN.md §4.2.
# CHANGELOG.md is RW for every role (one [Unreleased] entry per PR).
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
  reviewer)
    # Reviewer is read-only. Only CHANGELOG.md is permitted (rare:
    # to record a review-only metadata note). In practice the
    # reviewer should not open PRs at all.
    allowed='^CHANGELOG\.md$'
    ;;
  auditor)
    # Auditor files issues only — no commits expected. CHANGELOG only
    # for the rare case where the audit uncovers a documentation fix
    # the Orchestrator wants to land under the audit's banner.
    allowed='^CHANGELOG\.md$'
    ;;
  orchestrator)
    allowed='.*'
    ;;
  *)
    echo "role-guard: unknown role '$role'" >&2
    exit 2
    ;;
esac

if [[ -n "$base" ]] && git rev-parse --verify --quiet "$base" >/dev/null; then
  files=$(git diff --name-only "$base"...HEAD)
else
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
  echo "role-guard: role '$role' (source=$role_source, branch=$branch) may not modify:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  echo "" >&2
  echo "Allowed paths for '$role': $allowed" >&2
  echo "" >&2
  echo "Either rebrand the branch (research/, test/, dev/<slice>/, review/," >&2
  echo "audit/, chore/), apply the matching role:<role> PR label, set" >&2
  echo "AGENT_ROLE locally, or move the out-of-scope work into the right" >&2
  echo "role's PR." >&2
  exit 1
fi

###############################################################################
# 3. Trailer audit
###############################################################################

if [[ -n "$base" ]] && git rev-parse --verify --quiet "$base" >/dev/null; then
  commit_count=$(git rev-list --count "$base"..HEAD 2>/dev/null || echo 0)

  if [[ "$commit_count" -gt 0 ]]; then
    matching=$(git log "$base"..HEAD \
      --format='%(trailers:key=X-Bier-Role,valueonly,separator=%x09)' \
      | tr '\t' '\n' \
      | awk -v r="$role" 'NF && $1 == r { c++ } END { print c+0 }')

    if [[ "$matching" -eq 0 ]]; then
      echo "role-guard: trailer audit failed — no commit between $base..HEAD carries 'X-Bier-Role: $role'" >&2
      echo "" >&2
      echo "Commits inspected:" >&2
      git log "$base"..HEAD --format='  %h %s' >&2
      echo "" >&2
      echo "Fix: amend a commit to add the trailer, e.g." >&2
      echo "  git commit --amend --trailer 'X-Bier-Role: $role'" >&2
      echo "Or install .githooks/prepare-commit-msg to add it automatically." >&2
      exit 3
    fi
  fi
fi

count=$(echo "$files" | grep -c . || true)
echo "role-guard: ok (role=$role, source=$role_source, branch=$branch, $count files in scope)"
