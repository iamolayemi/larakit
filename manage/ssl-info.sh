#!/usr/bin/env bash
# =============================================================================
#  Manage — SSL Info
#  Show certificate expiry dates and chain details for configured domains.
#  Run standalone: sudo bash manage/ssl-info.sh
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

manage_header "SSL Info" "Certificate expiry and chain details for all configured domains."

check_cert() {
  local domain="$1"
  local cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"

  printf "\n  ${BOLD}%s${NC}\n" "$domain"

  if [[ -f "$cert_file" ]]; then
    local expiry issuer days_left
    expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2> /dev/null | cut -d= -f2)
    issuer=$(openssl x509 -issuer -noout -in "$cert_file" 2> /dev/null | sed 's/.*CN = //' | sed 's/,.*//')
    days_left=$((($(date -d "$expiry" +%s 2> /dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2> /dev/null) - $(date +%s)) / 86400))

    if ((days_left > 30)); then
      printf "  ${GREEN}✔${NC}  Expires: %-30s ${GREEN}%s days left${NC}\n" "$expiry" "$days_left"
    elif ((days_left > 7)); then
      printf "  ${YELLOW}!${NC}  Expires: %-30s ${YELLOW}%s days left${NC}\n" "$expiry" "$days_left"
    else
      printf "  ${RED}✘${NC}  Expires: %-30s ${RED}%s days left — renew now!${NC}\n" "$expiry" "$days_left"
    fi
    printf "  ${DIM}    Issuer:  %s${NC}\n" "$issuer"
  else
    # Try live check via openssl s_client
    local result
    result=$(echo | timeout 5 openssl s_client -connect "${domain}:443" -servername "$domain" 2> /dev/null | openssl x509 -noout -dates -issuer 2> /dev/null) || {
      printf "  ${RED}✘${NC}  No certificate found (Certbot or live check failed)\n"
      return
    }
    local expiry issuer
    expiry=$(echo "$result" | grep notAfter | cut -d= -f2)
    issuer=$(echo "$result" | grep issuer | sed 's/.*CN = //' | sed 's/,.*//')
    printf "  ${CYAN}~${NC}  Live check — Expires: %s\n" "$expiry"
    printf "  ${DIM}    Issuer:  %s${NC}\n" "$issuer"
  fi
}

# Collect domains to check
DOMAINS=()

# Load from credentials
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
[[ -n "$APP_DOMAIN" ]] && DOMAINS+=("$APP_DOMAIN")

# Scan Certbot live directory
if [[ -d /etc/letsencrypt/live ]]; then
  while IFS= read -r -d '' dir; do
    d=$(basename "$dir")
    [[ "$d" == "$APP_DOMAIN" ]] && continue
    DOMAINS+=("$d")
  done < <(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
fi

# Scan Nginx site configs for server_name
if [[ -d /etc/nginx/sites-enabled ]]; then
  while IFS= read -r domain; do
    [[ -z "$domain" || "$domain" == "_" ]] && continue
    # Deduplicate
    already=false
    for d in "${DOMAINS[@]}"; do [[ "$d" == "$domain" ]] && already=true && break; done
    [[ "$already" == "false" ]] && DOMAINS+=("$domain")
  done < <(grep -h "server_name" /etc/nginx/sites-enabled/* 2> /dev/null | grep -v "#" | sed 's/server_name//g; s/;//g' | tr ' ' '\n' | tr -d '\t' | grep '\.' | sort -u)
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  warn "No domains found. Pass a domain manually:"
  ask MANUAL_DOMAIN "Domain to check" ""
  [[ -n "$MANUAL_DOMAIN" ]] && DOMAINS+=("$MANUAL_DOMAIN")
fi

section "SSL Certificate Status"
for domain in "${DOMAINS[@]}"; do
  check_cert "$domain"
done

echo
info "To force renewal: ${DIM}sudo bash manage/ssl-renew.sh${NC}"
