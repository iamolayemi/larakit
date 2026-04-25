#!/usr/bin/env bash
# LaraKit — CLI smoke tests (no root, no installs)
# Usage: LARAKIT_HOME=/path/to/repo bash tests/test-cli.sh
set -euo pipefail

# larakit requires bash 4+ (associative arrays). Skip gracefully on older bash.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "  SKIP  CLI smoke tests require bash 4+ (found ${BASH_VERSION})"
  echo "        On macOS: brew install bash, then run with /usr/local/bin/bash"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LARAKIT_HOME="${LARAKIT_HOME:-$REPO_DIR}"
CLI="${REPO_DIR}/larakit"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS=0
FAIL=0

pass() {
  echo -e "  ${GREEN}PASS${NC}  $1"
  PASS=$((PASS + 1))
}
fail() {
  echo -e "  ${RED}FAIL${NC}  $1"
  FAIL=$((FAIL + 1))
}

assert_exits_zero() {
  local label="$1"
  shift
  if LARAKIT_HOME="$LARAKIT_HOME" bash "$CLI" "$@" > /dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_exits_nonzero() {
  local label="$1"
  shift
  if LARAKIT_HOME="$LARAKIT_HOME" bash "$CLI" "$@" > /dev/null 2>&1; then
    fail "$label (expected non-zero exit)"
  else
    pass "$label"
  fi
}

assert_output_contains() {
  local label="$1" pattern="$2"
  shift 2
  local out
  out=$(LARAKIT_HOME="$LARAKIT_HOME" bash "$CLI" "$@" 2>&1 || true)
  if echo "$out" | grep -q "$pattern"; then
    pass "$label"
  else
    fail "$label — expected '${pattern}' in output"
  fi
}

chmod +x "$CLI"

echo -e "\n${BOLD}LaraKit CLI Smoke Tests${NC}"
echo -e "${DIM}LARAKIT_HOME=${LARAKIT_HOME}${NC}\n"
divider() { echo -e "${DIM}$(printf '─%.0s' {1..50})${NC}"; }
divider

echo -e "\n${BOLD}Version & Help${NC}"
assert_exits_zero "larakit version" version
assert_output_contains "version output includes 'larakit'" "larakit" version
assert_exits_zero "larakit help" help
assert_exits_zero "larakit --help" --help
assert_exits_zero "larakit -h" -h

echo -e "\n${BOLD}List Commands${NC}"
assert_exits_zero "larakit list" list
assert_exits_zero "larakit list modules" list modules
assert_exits_zero "larakit list manage" list manage
assert_exits_zero "larakit ls" ls

echo -e "\n${BOLD}Install --help${NC}"
assert_exits_zero "larakit install --help" install --help
assert_exits_zero "larakit install php --help" install php --help
assert_exits_zero "larakit install mysql --help" install mysql --help
assert_exits_zero "larakit install redis --help" install redis --help
assert_exits_zero "larakit install ssl --help" install ssl --help
assert_exits_zero "larakit install typesense --help" install typesense --help
assert_exits_zero "larakit install elasticsearch --help" install elasticsearch --help
assert_exits_zero "larakit install rabbitmq --help" install rabbitmq --help
assert_exits_zero "larakit install nginx --help" install nginx --help

echo -e "\n${BOLD}Manage --help${NC}"
assert_exits_zero "larakit manage --help" manage --help
assert_exits_zero "larakit manage deploy --help" manage deploy --help
assert_exits_zero "larakit manage health --help" manage health --help
assert_exits_zero "larakit manage firewall --help" manage firewall --help
assert_exits_zero "larakit manage diagnose --help" manage diagnose --help
assert_exits_zero "larakit manage init --help" manage init --help
assert_exits_zero "larakit setup --help" setup --help

echo -e "\n${BOLD}Error Handling${NC}"
assert_exits_nonzero "Unknown command exits non-zero" notacommand
assert_exits_nonzero "Unknown module exits non-zero" install notamodule
assert_exits_nonzero "Unknown manage cmd exits non-zero" manage notacommand

divider
echo
printf "  Total: %d  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}\n\n" \
  "$((PASS + FAIL))" "$PASS" "$FAIL"

[[ $FAIL -eq 0 ]]
