#!/usr/bin/env bash
# =============================================================================
#  Module — Pre-flight Checks
#  Verifies OS, disk, RAM, and port availability before setup begins.
#  Run standalone: sudo bash modules/preflight.sh
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

module_header "Pre-flight Checks" "Validates OS, resources, and network before installation."
require_root
detect_os

PASS=0
WARN=0
FAIL=0
BLOCKERS=()

check_pass() {
  printf "  ${GREEN}${BOLD}✔${NC}  %s\n" "$1"
  PASS=$((PASS + 1))
}
check_warn() {
  printf "  ${YELLOW}${BOLD}!${NC}  %s\n" "$1"
  WARN=$((WARN + 1))
}
check_fail() {
  printf "  ${RED}${BOLD}✘${NC}  %s\n" "$1"
  FAIL=$((FAIL + 1))
  BLOCKERS+=("$1")
}

echo -e "\n  ${BOLD}Operating System${NC}"
divider

SUPPORTED_OS=("ubuntu:22.04" "ubuntu:24.04" "debian:12")
OS_KEY="${OS_ID}:${OS_VERSION}"
SUPPORTED=false
for s in "${SUPPORTED_OS[@]}"; do [[ "$s" == "$OS_KEY" ]] && SUPPORTED=true && break; done

if [[ "$SUPPORTED" == "true" ]]; then
  check_pass "OS: ${OS_ID^} ${OS_VERSION} ${OS_CODENAME:-} (supported)"
else
  check_warn "OS: ${OS_ID^} ${OS_VERSION} — not in tested list (Ubuntu 22.04/24.04, Debian 12). Proceeding at your own risk."
fi

if [[ "$(uname -m)" == "x86_64" ]] || [[ "$(uname -m)" == "aarch64" ]]; then
  check_pass "Architecture: $(uname -m)"
else
  check_fail "Architecture $(uname -m) may not be supported by all packages"
fi

echo -e "\n  ${BOLD}Resources${NC}"
divider

DISK_FREE_KB=$(df / | awk 'NR==2 {print $4}')
DISK_FREE_GB=$((DISK_FREE_KB / 1024 / 1024))
if [[ "$DISK_FREE_GB" -ge 20 ]]; then
  check_pass "Disk: ${DISK_FREE_GB}GB free (>= 20GB recommended)"
elif [[ "$DISK_FREE_GB" -ge 10 ]]; then
  check_warn "Disk: ${DISK_FREE_GB}GB free (20GB recommended for full stack)"
else
  check_fail "Disk: only ${DISK_FREE_GB}GB free — minimum 10GB required"
fi

RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
if [[ "$RAM_MB" -ge 2048 ]]; then
  check_pass "RAM: ${RAM_MB}MB (>= 2GB)"
elif [[ "$RAM_MB" -ge 1024 ]]; then
  check_warn "RAM: ${RAM_MB}MB — 2GB+ recommended for full stack"
else
  check_fail "RAM: only ${RAM_MB}MB — minimum 1GB required"
fi

SWAP_MB=$(free -m | awk '/^Swap:/ {print $2}')
if [[ "$SWAP_MB" -ge 1024 ]]; then
  check_pass "Swap: ${SWAP_MB}MB configured"
else
  check_warn "Swap: ${SWAP_MB}MB — consider adding 1-2GB swap (module 01 can do this)"
fi

echo -e "\n  ${BOLD}Network & Connectivity${NC}"
divider

if curl -fsSL --max-time 5 https://google.com -o /dev/null 2> /dev/null; then
  check_pass "Internet connectivity (HTTPS)"
else
  check_fail "No internet connectivity — packages cannot be downloaded"
fi

if curl -fsSL --max-time 5 https://ppa.launchpadcontent.net -o /dev/null 2> /dev/null; then
  check_pass "Launchpad PPA reachable (ondrej/php)"
else
  check_warn "Launchpad PPA unreachable — PHP PPA may fail (try apt-get update first)"
fi

if [[ "$(hostname -f 2> /dev/null || hostname)" != "localhost" ]]; then
  check_pass "Hostname: $(hostname -f 2> /dev/null || hostname)"
else
  check_warn "Hostname is 'localhost' — set a real hostname (module 01 handles this)"
fi

echo -e "\n  ${BOLD}Port Availability${NC}"
divider

check_port_free() {
  local label="$1" port="$2"
  if ss -tlnp 2> /dev/null | grep -q ":${port} " || netstat -tlnp 2> /dev/null | grep -q ":${port} " 2> /dev/null; then
    check_warn "Port ${port} (${label}) is already in use"
  else
    check_pass "Port ${port} (${label}) is free"
  fi
}

check_port_free "HTTP" 80
check_port_free "HTTPS" 443
check_port_free "MySQL" 3306
check_port_free "Redis" 6379
check_port_free "PgSQL" 5432

echo -e "\n  ${BOLD}Existing Software${NC}"
divider

for cmd in nginx apache2 mysql mariadb redis-server php; do
  if has_cmd "$cmd" || systemctl is-active --quiet "$cmd" 2> /dev/null; then
    check_warn "${cmd} is already installed — setup modules will offer reconfigure/reinstall/skip"
  fi
done
check_pass "Pre-existing software scan complete"

echo
divider
printf "  Results — Pass: ${GREEN}%d${NC}  Warn: ${YELLOW}%d${NC}  Fail: ${RED}%d${NC}\n\n" "$PASS" "$WARN" "$FAIL"

if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  echo -e "  ${RED}${BOLD}Blocking issues:${NC}"
  for b in "${BLOCKERS[@]}"; do
    echo -e "  ${RED}•${NC}  $b"
  done
  echo
  ask_yn CONTINUE_ANYWAY "Continue setup despite blockers?" "n"
  [[ "$CONTINUE_ANYWAY" != "true" ]] && {
    error "Aborting. Resolve the issues above and re-run."
    exit 1
  }
elif [[ "$WARN" -gt 0 ]]; then
  ask_yn CONTINUE_WARNED "Warnings found. Continue anyway?" "y"
  [[ "$CONTINUE_WARNED" != "true" ]] && {
    info "Aborted."
    exit 0
  }
fi

success "Pre-flight checks passed. Ready to install."
