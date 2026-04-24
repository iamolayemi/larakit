#!/usr/bin/env bash
# =============================================================================
#  Manage — Diagnose
#  Health check + firewall audit + SSL check in one shot.
#  Run standalone: sudo bash manage/diagnose.sh
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
else
  # Called from larakit CLI or setup.sh — source libs from SETUP_BASE_DIR
  source "${SETUP_BASE_DIR}/lib/colors.sh"
  source "${SETUP_BASE_DIR}/lib/prompts.sh"
  source "${SETUP_BASE_DIR}/lib/creds.sh"
  source "${SETUP_BASE_DIR}/lib/utils.sh"
fi

module_header "Diagnose" "Health + firewall audit + SSL certificate check in one shot"
require_root

_run_sub() {
  local label="$1" script="${SETUP_BASE_DIR:-$(dirname "$_D")/..}/manage/$2"
  section "$label"
  if [[ -f "$script" ]]; then
    bash "$script"
  else
    warn "Script not found: $2"
  fi
  echo
}

_run_sub "Service Health" "health.sh"
_run_sub "Firewall Audit" "firewall-audit.sh"

section "SSL Certificates"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
if [[ -n "$APP_DOMAIN" ]] && has_cmd openssl; then
  step "Checking certificate for ${APP_DOMAIN}..."
  expiry=$(echo | openssl s_client -servername "$APP_DOMAIN" \
    -connect "${APP_DOMAIN}:443" 2> /dev/null \
    | openssl x509 -noout -enddate 2> /dev/null \
    | cut -d= -f2 || echo "")

  if [[ -n "$expiry" ]]; then
    expiry_epoch=$(date -d "$expiry" +%s 2> /dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2> /dev/null || echo 0)
    now_epoch=$(date +%s)
    days_left=$(((expiry_epoch - now_epoch) / 86400))

    if [[ $days_left -lt 14 ]]; then
      warn "Certificate expires in ${days_left} days (${expiry}) — renew soon!"
      echo -e "  ${DIM}Run: larakit manage ssl-renew${NC}"
    elif [[ $days_left -lt 30 ]]; then
      warn "Certificate expires in ${days_left} days (${expiry})"
    else
      success "Certificate valid for ${days_left} more days (expires ${expiry})"
    fi
  else
    warn "Could not retrieve certificate for ${APP_DOMAIN} — is HTTPS configured?"
  fi

  if has_cmd certbot; then
    step "Certbot certificates:"
    certbot certificates 2> /dev/null | grep -E "Domains:|Expiry Date:|Certificate Name:" | sed 's/^/  /' || true
  fi
else
  [[ -z "$APP_DOMAIN" ]] && warn "No APP_DOMAIN saved — run 'larakit init' first."
  ! has_cmd openssl && warn "openssl not found."
fi

echo
section "Summary"
echo -e "  Run individual checks:"
printf "  ${DIM}%-40s%s${NC}\n" "larakit manage health" "Service statuses + failed jobs"
printf "  ${DIM}%-40s%s${NC}\n" "larakit manage firewall" "UFW rules + open ports"
printf "  ${DIM}%-40s%s${NC}\n" "larakit manage ssl-renew" "Force cert renewal"
printf "  ${DIM}%-40s%s${NC}\n" "larakit manage report" "Full stack overview"
echo
