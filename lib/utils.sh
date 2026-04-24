#!/usr/bin/env bash
# LaraKit — Shared utilities

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "This module must run as root. Use: sudo bash $0"
    exit 1
  fi
}

has_cmd() { command -v "$1" &> /dev/null; }

pkg_installed() { dpkg -l "$1" 2> /dev/null | grep -q "^ii"; }

pkg_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
}

service_running() { systemctl is-active --quiet "$1"; }

service_enable_start() {
  systemctl enable "$1" --quiet 2> /dev/null
  systemctl restart "$1"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    export OS_ID="$ID"
    export OS_VERSION="$VERSION_ID"
    export OS_CODENAME="${VERSION_CODENAME:-}"
  else
    error "Cannot detect OS. Only Debian/Ubuntu supported."
    exit 1
  fi
}

get_public_ip() {
  curl -s --max-time 5 https://api.ipify.org 2> /dev/null \
    || curl -s --max-time 5 https://icanhazip.com 2> /dev/null \
    || hostname -I 2> /dev/null | awk '{print $1}'
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] && cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
}

run_or_dry() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    dim "[DRY RUN] $*"
  else
    "$@"
  fi
}

add_firewall_rule() {
  local port="$1" proto="${2:-tcp}"
  if has_cmd ufw; then
    ufw allow "${port}/${proto}" --quiet
  fi
}

# module_header <title> <description>
module_header() {
  section "$1"
  if [[ -n "${2:-}" ]]; then
    echo -e "  ${DIM}$2${NC}\n"
  fi
}

# spinner — shows while a background pid runs
spinner() {
  local pid=$1 msg="${2:-Working...}"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  tput civis 2> /dev/null || true
  while kill -0 "$pid" 2> /dev/null; do
    i=$(((i + 1) % ${#spin}))
    printf "\r  ${CYAN}${spin:$i:1}${NC}  %s" "$msg"
    sleep 0.1
  done
  tput cnorm 2> /dev/null || true
  printf "\r%s\r" "$(printf ' %.0s' {1..60})"
}

# run_quiet <msg> <cmd...>
run_quiet() {
  local msg="$1"
  shift
  local log
  log=$(mktemp)
  "$@" > "$log" 2>&1 &
  local pid=$!
  spinner "$pid" "$msg"
  if wait "$pid"; then
    success "$msg"
    rm -f "$log"
    return 0
  else
    error "$msg — FAILED"
    echo -e "${DIM}--- Error output ---${NC}"
    tail -20 "$log"
    rm -f "$log"
    return 1
  fi
}

# Ensure a line exists in a file (idempotent)
ensure_line() {
  local line="$1" file="$2"
  grep -qF "$line" "$file" 2> /dev/null || echo "$line" >> "$file"
}

# Replace or insert a key=value pair in a file
set_env_value() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file" 2> /dev/null; then
    local tmp
    tmp=$(mktemp)
    while IFS= read -r line; do
      if [[ "$line" =~ ^${key}= ]]; then
        echo "${key}=${value}"
      else
        echo "$line"
      fi
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# Lib loading helper used by standalone modules
_load_libs() {
  local base_dir="$1"
  local base_url="${2:-}"
  local libs=(colors.sh prompts.sh creds.sh utils.sh notify.sh)

  for lib in "${libs[@]}"; do
    if [[ -f "${base_dir}/lib/${lib}" ]]; then
      # shellcheck disable=SC1090
      source "${base_dir}/lib/${lib}"
    elif [[ -n "$base_url" ]]; then
      local tmp
      tmp=$(mktemp)
      curl -fsSL "${base_url}/lib/${lib}" -o "$tmp"
      # shellcheck disable=SC1090
      source "$tmp"
      rm -f "$tmp"
    else
      echo "ERROR: Cannot find lib/${lib}" >&2
      exit 1
    fi
  done
}
