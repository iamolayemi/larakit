#!/usr/bin/env bash
# =============================================================================
#  Manage — Swap
#  Add, resize, or remove swap space.
#  Run standalone: sudo bash manage/swap.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh" 2> /dev/null || true
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh" 2> /dev/null || true
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

module_header "Swap Manager" "Add, resize, or remove swap space on this server."
require_root

section "Current Swap"
if swapon --show 2> /dev/null | grep -q .; then
  swapon --show
  echo
  free -h | grep -E "Mem:|Swap:"
else
  info "No swap currently configured."
fi
echo

ask_choice SWAP_ACTION "Action:" \
  "add    — create a new swap file" \
  "remove — turn off and delete swap" \
  "status — show current swap only"
SWAP_ACTION="${SWAP_ACTION%% *}"

case "$SWAP_ACTION" in
  add)
    ask_choice SWAP_SIZE "Swap size:" "2G" "4G" "8G" "1G"
    SWAP_SIZE="${SWAP_SIZE%% *}"

    SWAP_FILE="/swapfile"
    ask SWAP_FILE "Swap file path" "$SWAP_FILE"

    if [[ -f "$SWAP_FILE" ]]; then
      ask_yn REPLACE_SWAP "Swap file already exists at ${SWAP_FILE}. Replace it?" "n"
      if [[ "$REPLACE_SWAP" == "true" ]]; then
        run_or_dry swapoff "$SWAP_FILE" 2> /dev/null || true
        run_or_dry rm -f "$SWAP_FILE"
      else
        info "Keeping existing swap."
        exit 0
      fi
    fi

    step "Creating ${SWAP_SIZE} swap file at ${SWAP_FILE}..."
    # fallocate is faster; fall back to dd if not available
    if has_cmd fallocate; then
      run_or_dry fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    else
      size_mb=$(echo "$SWAP_SIZE" | sed 's/G//')
      size_mb=$((size_mb * 1024))
      run_or_dry dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mb" status=progress
    fi
    run_or_dry chmod 600 "$SWAP_FILE"
    run_or_dry mkswap "$SWAP_FILE"
    run_or_dry swapon "$SWAP_FILE"

    if ! grep -q "^${SWAP_FILE}" /etc/fstab 2> /dev/null; then
      echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
      success "Added ${SWAP_FILE} to /etc/fstab (persists across reboots)."
    fi

    step "Setting vm.swappiness=10 (production-safe)..."
    echo "vm.swappiness=10" > /etc/sysctl.d/60-swap.conf
    sysctl -p /etc/sysctl.d/60-swap.conf > /dev/null 2>&1
    success "vm.swappiness set to 10."

    echo
    success "Swap active:"
    swapon --show
    ;;

  remove)
    SWAP_FILE="/swapfile"
    ask SWAP_FILE "Swap file to remove" "$SWAP_FILE"
    [[ ! -f "$SWAP_FILE" ]] && {
      error "File not found: ${SWAP_FILE}"
      exit 1
    }
    confirm_or_exit "Turn off and delete ${SWAP_FILE}?"

    swapoff "$SWAP_FILE" 2> /dev/null || warn "Swap was not active."
    rm -f "$SWAP_FILE"

    tmp=$(mktemp)
    grep -v "^${SWAP_FILE}" /etc/fstab > "$tmp" || true
    mv "$tmp" /etc/fstab

    success "Swap removed and fstab updated."
    ;;

  status)
    if ! swapon --show 2> /dev/null | grep -q .; then
      info "No swap configured."
    fi
    ;;
esac
