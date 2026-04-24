#!/usr/bin/env bash
# =============================================================================
#  Manage — Queue Scale
#  Adjust Supervisor worker count live without editing config files.
#  Run standalone: sudo bash manage/queue-scale.sh
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

module_header "Queue Scale" "Adjust Supervisor worker count live — no config file editing required."
require_root

if ! has_cmd supervisorctl; then
  error "Supervisor is not installed. Install it with: larakit install queue"
  exit 1
fi

# ---- Show current state -----------------------------------------------------
section "Current Worker Programs"
supervisorctl status 2> /dev/null | grep -v "^$" | while IFS= read -r line; do
  if echo "$line" | grep -q "RUNNING"; then
    printf "  ${GREEN}●${NC} %s\n" "$line"
  elif echo "$line" | grep -q "STOPPED\|EXITED"; then
    printf "  ${RED}●${NC} %s\n" "$line"
  else
    printf "  ${YELLOW}●${NC} %s\n" "$line"
  fi
done
echo

# ---- Find worker config files -----------------------------------------------
CONF_DIR="/etc/supervisor/conf.d"
mapfile -t WORKER_CONFS < <(grep -rl "numprocs\|queue:work\|queue:listen" "$CONF_DIR" 2> /dev/null | sort)

if [[ ${#WORKER_CONFS[@]} -eq 0 ]]; then
  error "No Supervisor queue worker configs found in ${CONF_DIR}"
  info "Install queue workers with: larakit install queue"
  exit 1
fi

echo -e "  ${BOLD}Worker config files:${NC}\n"
for i in "${!WORKER_CONFS[@]}"; do
  conf="${WORKER_CONFS[$i]}"
  current=$(grep "^numprocs" "$conf" 2> /dev/null | cut -d'=' -f2 | tr -d ' ' || echo "1")
  program=$(grep "^\[program:" "$conf" 2> /dev/null | head -1 | tr -d '[]' | sed 's/program://')
  printf "  ${BOLD}%d)${NC} %-35s ${DIM}current: %s workers${NC}\n" "$((i + 1))" "$program" "$current"
done
echo

ask CONF_CHOICE "Select config to scale (number)" "1"
if ! [[ "$CONF_CHOICE" =~ ^[0-9]+$ ]] \
  || [[ "$CONF_CHOICE" -lt 1 ]] \
  || [[ "$CONF_CHOICE" -gt "${#WORKER_CONFS[@]}" ]]; then
  error "Invalid selection."
  exit 1
fi

SELECTED_CONF="${WORKER_CONFS[$((CONF_CHOICE - 1))]}"
CURRENT_PROCS=$(grep "^numprocs" "$SELECTED_CONF" 2> /dev/null | cut -d'=' -f2 | tr -d ' ' || echo "1")
PROGRAM_NAME=$(grep "^\[program:" "$SELECTED_CONF" | head -1 | tr -d '[]' | sed 's/program://')

info "Config:   ${SELECTED_CONF}"
info "Program:  ${PROGRAM_NAME}"
info "Current:  ${CURRENT_PROCS} workers"
echo

ask_choice NEW_PROCS "New worker count:" "2" "4" "8" "1"
NEW_PROCS="${NEW_PROCS%% *}"

# Validate it's a number
if ! [[ "$NEW_PROCS" =~ ^[0-9]+$ ]] || [[ "$NEW_PROCS" -lt 1 ]] || [[ "$NEW_PROCS" -gt 32 ]]; then
  error "Worker count must be between 1 and 32."
  exit 1
fi

confirm_or_exit "Scale '${PROGRAM_NAME}' from ${CURRENT_PROCS} to ${NEW_PROCS} workers?"

# ---- Update config file -----------------------------------------------------
step "Updating ${SELECTED_CONF}..."
backup_file "$SELECTED_CONF"

tmp=$(mktemp)
grep -v "^numprocs" "$SELECTED_CONF" > "$tmp"
# Insert numprocs after [program:...] line
awk -v np="$NEW_PROCS" '
  /^\[program:/ { print; print "numprocs=" np; next }
  /^numprocs/ { next }
  { print }
' "$SELECTED_CONF" > "$tmp"
mv "$tmp" "$SELECTED_CONF"

success "Config updated: numprocs=${NEW_PROCS}"

# ---- Reload Supervisor ------------------------------------------------------
step "Reloading Supervisor configuration..."
run_or_dry supervisorctl reread
run_or_dry supervisorctl update
run_or_dry supervisorctl restart "${PROGRAM_NAME}:*" 2> /dev/null \
  || run_or_dry supervisorctl restart "$PROGRAM_NAME" 2> /dev/null || true

echo
step "New worker status:"
supervisorctl status 2> /dev/null | grep "$PROGRAM_NAME" | while IFS= read -r line; do
  printf "  ${GREEN}●${NC} %s\n" "$line"
done

echo
success "Queue workers scaled: ${CURRENT_PROCS} → ${NEW_PROCS}"
info "Config saved to: ${SELECTED_CONF}"
