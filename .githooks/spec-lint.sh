#!/usr/bin/env bash
# spec-lint.sh — validate every spec/conformance/cases/*.yaml from §8 #8.
#
# Phase 0 ships the gate but the cases directory does not exist yet
# (the Researcher creates it in Phase 1). The script no-ops when there
# is nothing to lint, and graduates to schema validation against
# spec/case.schema.json once that file appears.

set -euo pipefail

cases_dir="spec/conformance/cases"
schema="spec/case.schema.json"

if [[ ! -d "$cases_dir" ]]; then
  echo "spec-lint: $cases_dir does not exist yet — skipping (Phase 0)"
  exit 0
fi

shopt -s nullglob
yaml_files=("$cases_dir"/*.yaml)
shopt -u nullglob

if [[ ${#yaml_files[@]} -eq 0 ]]; then
  echo "spec-lint: no case files in $cases_dir — skipping"
  exit 0
fi

fail=0
for f in "${yaml_files[@]}"; do
  if ! python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    echo "spec-lint: invalid YAML — $f" >&2
    fail=1
  fi
done

if [[ -f "$schema" ]]; then
  if ! command -v ajv >/dev/null 2>&1; then
    echo "spec-lint: $schema present but 'ajv' CLI is not installed; YAML-only check applied" >&2
  else
    for f in "${yaml_files[@]}"; do
      if ! ajv validate -s "$schema" -d "$f" --strict=false >/dev/null 2>&1; then
        echo "spec-lint: schema violation — $f" >&2
        fail=1
      fi
    done
  fi
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi

echo "spec-lint: ok (${#yaml_files[@]} cases checked)"
