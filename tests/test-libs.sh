#!/usr/bin/env bash
# Test that lib functions load and behave correctly
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok() {
  printf "  \033[32mPASS\033[0m  %s\n" "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf "  \033[31mFAIL\033[0m  %s\n" "$1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    fail "$label (expected: '$expected', got: '$actual')"
  fi
}

assert_len() {
  local label="$1" min="$2" actual="${#3}"
  if [[ "$actual" -ge "$min" ]]; then
    ok "$label"
  else
    fail "$label (expected length >= $min, got $actual)"
  fi
}

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    ok "$label"
  else
    fail "$label (value '$actual' does not match '$pattern')"
  fi
}

echo
echo "  Library tests"
echo "  ───────────────────────────────────────────────────"

# Source libs
CREDS_FILE="$(mktemp)"
export CREDS_FILE
export SETUP_BASE_URL="https://raw.githubusercontent.com/iamolayemi/larakit/main"
export SETUP_LOADED=1

source "${ROOT}/lib/colors.sh"
source "${ROOT}/lib/prompts.sh"
source "${ROOT}/lib/creds.sh"
source "${ROOT}/lib/utils.sh"

ok "All libs sourced without error"

# Colors
[[ -n "$RED" ]] && ok "RED defined" || fail "RED not defined"
[[ -n "$GREEN" ]] && ok "GREEN defined" || fail "GREEN not defined"
[[ -n "$NC" ]] && ok "NC defined" || fail "NC not defined"

# gen_password
pw=$(gen_password 24)
assert_len "gen_password produces >= 24 chars" 24 "$pw"

# gen_secret
sec=$(gen_secret 32)
assert_len "gen_secret produces >= 32 chars" 32 "$sec"
assert_match "gen_secret is alphanumeric" '^[A-Za-z0-9]+$' "$sec"

# creds round-trip
creds_save TEST_KEY "hello-world"
loaded=$(creds_load TEST_KEY)
assert_eq "creds round-trip (save + load)" "hello-world" "$loaded"

# creds_load missing key returns empty
missing=$(creds_load NONEXISTENT_KEY_XYZ 2> /dev/null || true)
assert_eq "creds_load missing key returns empty" "" "$missing"

# has_cmd
has_cmd bash && ok "has_cmd: bash found" || fail "has_cmd: bash not found"
has_cmd __nonexistent_cmd_xyz__ && fail "has_cmd: false positive" || ok "has_cmd: unknown cmd returns false"

# set_env_value
tmpenv="$(mktemp)"
echo "FOO=old" > "$tmpenv"
set_env_value FOO "new" "$tmpenv"
env_val=$(grep "^FOO=" "$tmpenv" | cut -d= -f2)
assert_eq "set_env_value replaces existing key" "new" "$env_val"

set_env_value BAR "added" "$tmpenv"
env_val=$(grep "^BAR=" "$tmpenv" | cut -d= -f2)
assert_eq "set_env_value adds missing key" "added" "$env_val"
rm -f "$tmpenv"

# ensure_line
tmpfile="$(mktemp)"
ensure_line "my-unique-line" "$tmpfile"
ensure_line "my-unique-line" "$tmpfile"
count=$(grep -c "my-unique-line" "$tmpfile")
assert_eq "ensure_line is idempotent" "1" "$count"
rm -f "$tmpfile"

# backup_file
tmpbak="$(mktemp)"
echo "original" > "$tmpbak"
backup_file "$tmpbak"
bak_count=$(find "$(dirname "$tmpbak")" -maxdepth 1 -name "$(basename "$tmpbak").bak.*" 2> /dev/null | wc -l | tr -d ' ')
assert_eq "backup_file creates .bak copy" "1" "$bak_count"
find "$(dirname "$tmpbak")" -maxdepth 1 -name "$(basename "$tmpbak").bak.*" -delete 2> /dev/null || true
rm -f "$tmpbak"

# Cleanup creds temp file
rm -f "$CREDS_FILE"

echo "  ───────────────────────────────────────────────────"
printf "  Total: %d  Pass: \033[32m%d\033[0m  Fail: \033[31m%d\033[0m\n\n" $((PASS + FAIL)) "$PASS" "$FAIL"

[[ "$FAIL" -eq 0 ]] || exit 1
