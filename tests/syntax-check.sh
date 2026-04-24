#!/usr/bin/env bash
# Syntax-check all .sh files in the project
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
ERRORS=()

check_file() {
  local f="$1"
  local rel="${f#"${ROOT}/"}"
  if bash -n "$f" 2> /tmp/bash-syntax-err; then
    printf "  \033[32mPASS\033[0m  %s\n" "$rel"
    PASS=$((PASS + 1))
  else
    printf "  \033[31mFAIL\033[0m  %s\n" "$rel"
    while IFS= read -r line; do
      printf "        %s\n" "$line"
    done < /tmp/bash-syntax-err
    ERRORS+=("$rel")
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "  Syntax check — all .sh files"
echo "  ───────────────────────────────────────────────────"

while IFS= read -r -d '' file; do
  check_file "$file"
done < <(find "$ROOT" -name "*.sh" -not -path "*/\.*" -print0 | sort -z)

# Also check the larakit binary (no .sh extension)
[[ -f "${ROOT}/larakit" ]] && check_file "${ROOT}/larakit"

echo "  ───────────────────────────────────────────────────"
printf "  Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n\n" $((PASS + FAIL)) "$PASS" "$FAIL"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "  Failed files:"
  for e in "${ERRORS[@]}"; do
    printf "    - %s\n" "$e"
  done
  echo
  exit 1
fi
