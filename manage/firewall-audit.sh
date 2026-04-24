#!/usr/bin/env bash
# =============================================================================
#  Manage — Firewall Audit
#  Review UFW rules and open ports for unnecessary exposure.
#  Run standalone: sudo bash manage/firewall-audit.sh
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

module_header "Firewall Audit" "Review UFW rules, open ports, and surface anything that looks unnecessary"
require_root

section "UFW Status"
if has_cmd ufw; then
  ufw status verbose 2> /dev/null || true
else
  warn "UFW is not installed."
fi

echo
section "Listening Ports"
step "TCP ports in use:"
if has_cmd ss; then
  ss -tlnp 2> /dev/null | tail -n +2 | awk '{print "  " $4 "\t" $6}' | column -t || true
elif has_cmd netstat; then
  netstat -tlnp 2> /dev/null | tail -n +3 || true
fi

echo
step "UDP ports in use:"
if has_cmd ss; then
  ss -ulnp 2> /dev/null | tail -n +2 | awk '{print "  " $4 "\t" $5}' | column -t || true
fi

echo
section "Well-Known Service Ports"

declare -A KNOWN_PORTS=(
  [22]="SSH"
  [80]="HTTP (Nginx/Apache)"
  [443]="HTTPS (Nginx/Apache)"
  [3306]="MySQL/MariaDB"
  [5432]="PostgreSQL"
  [6379]="Redis"
  [8080]="Nginx backend (Varnish)"
  [8108]="Typesense"
  [7700]="Meilisearch"
  [1025]="Mailpit SMTP"
  [8025]="Mailpit Web UI"
  [6001]="Reverb WebSocket"
  [8000]="Octane"
  [9000]="PHP-FPM"
  [9090]="Netdata"
  [3001]="UptimeKuma"
  [9000]="MinIO API"
  [9001]="MinIO Console"
)

for port in "${!KNOWN_PORTS[@]}"; do
  if ss -tlnp 2> /dev/null | grep -q ":${port} " || ss -ulnp 2> /dev/null | grep -q ":${port} "; then
    printf "  ${GREEN}${BOLD}●${NC}  %-6s %s\n" "${port}" "${KNOWN_PORTS[$port]}"
  fi
done | sort -t: -k1 -n

echo
section "Potential Risks"

RISKS=0

if has_cmd ufw && ufw status 2> /dev/null | grep -q "Status: inactive"; then
  warn "UFW firewall is INACTIVE — no rules are being enforced."
  RISKS=$((RISKS + 1))
fi

if ss -tlnp 2> /dev/null | grep -q "0.0.0.0:3306\|:::3306"; then
  warn "MySQL (3306) is listening on ALL interfaces — should be 127.0.0.1 only."
  echo -e "  ${DIM}Fix: edit /etc/mysql/mysql.conf.d/mysqld.cnf → bind-address = 127.0.0.1${NC}"
  RISKS=$((RISKS + 1))
fi

if ss -tlnp 2> /dev/null | grep -q "0.0.0.0:5432\|:::5432"; then
  warn "PostgreSQL (5432) is listening on ALL interfaces — should be 127.0.0.1 only."
  echo -e "  ${DIM}Fix: edit /etc/postgresql/*/main/postgresql.conf → listen_addresses = 'localhost'${NC}"
  RISKS=$((RISKS + 1))
fi

if ss -tlnp 2> /dev/null | grep -q "0.0.0.0:6379\|:::6379"; then
  warn "Redis (6379) is listening on ALL interfaces — should be 127.0.0.1 only."
  echo -e "  ${DIM}Fix: edit /etc/redis/redis.conf → bind 127.0.0.1${NC}"
  RISKS=$((RISKS + 1))
fi

if ss -tlnp 2> /dev/null | grep -q "0.0.0.0:9000\|:::9000"; then
  warn "Something is listening on port 9000 on all interfaces (PHP-FPM or MinIO)."
  echo -e "  ${DIM}Verify this is intentional and add a UFW rule if needed.${NC}"
  RISKS=$((RISKS + 1))
fi

if ss -tlnp 2> /dev/null | grep -q ":23 "; then
  warn "Telnet (port 23) appears to be open — close it immediately."
  RISKS=$((RISKS + 1))
fi

if [[ $RISKS -eq 0 ]]; then
  success "No obvious firewall risks detected."
else
  echo
  warn "${RISKS} potential issue(s) found — review the warnings above."
fi

echo
section "Suggestions"
echo -e "  ${DIM}• Only expose ports 22, 80, and 443 externally.${NC}"
echo -e "  ${DIM}• Database and cache ports (3306, 5432, 6379) should bind to 127.0.0.1.${NC}"
echo -e "  ${DIM}• Internal service ports (Typesense, Meilisearch, Octane) should NOT be in UFW allow rules.${NC}"
echo -e "  ${DIM}• Run 'ufw status numbered' to view rules by number, 'ufw delete N' to remove one.${NC}"
echo
