#!/usr/bin/env bash
# =============================================================================
#  Manage — Performance Test
#  Benchmark the app with ab or wrk and report req/s and latency.
#  Run standalone: sudo bash manage/performance-test.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh"
  _src() {
    local f="$1"
    if [[ -f "${_BASE}/lib/${f}" ]]; then source "${_BASE}/lib/${f}"; else
      local t
      t=$(mktemp)
      curl -fsSL "${SETUP_BASE_URL}/lib/${f}" -o "$t" && source "$t"
      rm -f "$t"
    fi
  }
  _src colors.sh
  _src prompts.sh
  _src creds.sh
  _src utils.sh
  export SETUP_LOADED=1
fi

module_header "Performance Test" "Fire ab or wrk against your app and report req/s and latency"

APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"

ask TARGET_URL "Target URL" "${APP_DOMAIN:+https://${APP_DOMAIN}/}"
ask CONCURRENCY "Concurrent connections" "10"
ask REQUESTS "Total requests (ab only)" "1000"
ask DURATION "Duration in seconds (wrk only)" "30"

AVAILABLE_TOOLS=()
has_cmd wrk && AVAILABLE_TOOLS+=("wrk (modern, recommended)")
has_cmd ab && AVAILABLE_TOOLS+=("ab (Apache Bench, built-in)")
has_cmd hey && AVAILABLE_TOOLS+=("hey (Go-based)")

if [[ ${#AVAILABLE_TOOLS[@]} -eq 0 ]]; then
  warn "No load testing tool found. Installing Apache Bench..."
  pkg_install apache2-utils
  AVAILABLE_TOOLS+=("ab (Apache Bench, built-in)")
fi

ask_choice TOOL "Tool to use" "${AVAILABLE_TOOLS[@]}"
TOOL="${TOOL%% *}"

echo
confirm_or_exit "Run performance test against ${TARGET_URL}?"

echo
section "Results"

case "$TOOL" in
  wrk)
    step "Running wrk — ${DURATION}s × ${CONCURRENCY} connections..."
    echo
    wrk -t"${CONCURRENCY}" -c"${CONCURRENCY}" -d"${DURATION}s" \
      --latency "$TARGET_URL" 2>&1
    ;;
  ab)
    step "Running ab — ${REQUESTS} requests × ${CONCURRENCY} concurrent..."
    echo
    ab -n "$REQUESTS" -c "$CONCURRENCY" -k \
      -H "Accept-Encoding: gzip" \
      "$TARGET_URL" 2>&1
    ;;
  hey)
    step "Running hey — ${REQUESTS} requests × ${CONCURRENCY} concurrent..."
    echo
    hey -n "$REQUESTS" -c "$CONCURRENCY" "$TARGET_URL" 2>&1
    ;;
esac

echo
success "Performance test complete."
echo -e "  ${DIM}Tip: run this before and after 'larakit install tuning' to measure the impact.${NC}"
