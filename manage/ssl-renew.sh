#!/usr/bin/env bash
# =============================================================================
#  Manage — Ssl Renew
#  Force SSL certificate renewal via Certbot.
#  Run standalone: sudo bash manage/ssl-renew.sh
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

if ! has_cmd certbot; then
  error "Certbot not installed. Run module 08-ssl.sh first."
  exit 1
fi

step "Listing current certificates..."
certbot certificates 2> /dev/null | grep -E "(Found|Domains|Expiry)" | sed 's/^/  /'

echo
ask_yn DRY_RUN "Do a dry run first?" "y"

if [[ "$DRY_RUN" == "true" ]]; then
  step "Running dry run..."
  if certbot renew --dry-run 2>&1 | tail -10; then
    success "Dry run passed."
  else
    error "Dry run failed."
    exit 1
  fi
fi

confirm_or_exit "Force renewal now?"

step "Renewing certificates..."
certbot renew --force-renewal --post-hook "systemctl reload nginx" 2>&1 | tail -20
success "Certificates renewed and Nginx reloaded."
