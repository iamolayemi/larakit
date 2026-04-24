#!/usr/bin/env bash
# =============================================================================
#  Manage — SSH Keys
#  View, add, or remove authorized SSH keys for the deploy user.
#  Run standalone: sudo bash manage/ssh-keys.sh
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
else
  # Called from larakit CLI or setup.sh — source libs from SETUP_BASE_DIR
  source "${SETUP_BASE_DIR}/lib/colors.sh"
  source "${SETUP_BASE_DIR}/lib/prompts.sh"
  source "${SETUP_BASE_DIR}/lib/creds.sh"
  source "${SETUP_BASE_DIR}/lib/utils.sh"
fi

module_header "SSH Keys" "View, add, or remove authorized SSH public keys for the deploy user."
require_root

DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
ask SSH_USER "Manage keys for which user?" "$DEPLOY_USER"

if [[ "$SSH_USER" == "root" ]]; then
  AUTH_KEYS="/root/.ssh/authorized_keys"
  SSH_DIR="/root/.ssh"
else
  AUTH_KEYS="/home/${SSH_USER}/.ssh/authorized_keys"
  SSH_DIR="/home/${SSH_USER}/.ssh"
fi

ask_choice SSH_ACTION "Action:" \
  "list   — show installed keys" \
  "add    — add a public key" \
  "remove — remove a key"
SSH_ACTION="${SSH_ACTION%% *}"

case "$SSH_ACTION" in
  list)
    section "Authorized Keys for ${SSH_USER}"
    if [[ ! -f "$AUTH_KEYS" ]]; then
      info "No authorized_keys file found at ${AUTH_KEYS}"
      exit 0
    fi
    count=0
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      count=$((count + 1))
      keytype=$(echo "$line" | awk '{print $1}')
      keycomment=$(echo "$line" | awk '{print $3}')
      printf "  ${BOLD}%d)${NC} ${CYAN}%s${NC}  ${DIM}%s${NC}\n" "$count" "$keytype" "${keycomment:-no comment}"
    done < "$AUTH_KEYS"
    echo
    info "${count} key(s) installed for ${SSH_USER}."
    ;;

  add)
    section "Add SSH Public Key for ${SSH_USER}"
    echo -e "  ${DIM}Paste the full public key (ssh-ed25519 AAAA... or ssh-rsa AAAA...)${NC}\n"
    ask NEW_KEY "Public key" ""
    [[ -z "$NEW_KEY" ]] && {
      error "Key cannot be empty."
      exit 1
    }

    keytype=$(echo "$NEW_KEY" | awk '{print $1}')
    case "$keytype" in
      ssh-rsa | ssh-ed25519 | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | sk-ssh-ed25519@openssh.com) ;;
      *)
        error "Unrecognized key type: '${keytype}'"
        exit 1
        ;;
    esac

    run_or_dry mkdir -p "$SSH_DIR"
    run_or_dry touch "$AUTH_KEYS"
    run_or_dry chmod 700 "$SSH_DIR"
    run_or_dry chmod 600 "$AUTH_KEYS"

    if grep -qF "$NEW_KEY" "$AUTH_KEYS" 2> /dev/null; then
      warn "That key is already present in ${AUTH_KEYS}"
    else
      echo "$NEW_KEY" >> "$AUTH_KEYS"
      [[ "$SSH_USER" != "root" ]] && chown -R "${SSH_USER}:${SSH_USER}" "$SSH_DIR" 2> /dev/null || true
      success "Key added to ${AUTH_KEYS}"
    fi
    ;;

  remove)
    section "Remove SSH Key for ${SSH_USER}"
    if [[ ! -f "$AUTH_KEYS" ]]; then
      info "No authorized_keys file found."
      exit 0
    fi
    keys=()
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      keys+=("$line")
    done < "$AUTH_KEYS"

    if [[ ${#keys[@]} -eq 0 ]]; then
      info "No keys installed."
      exit 0
    fi

    for i in "${!keys[@]}"; do
      keytype=$(echo "${keys[$i]}" | awk '{print $1}')
      keycomment=$(echo "${keys[$i]}" | awk '{print $3}')
      printf "  ${BOLD}%d)${NC} ${CYAN}%s${NC}  ${DIM}%s${NC}\n" "$((i + 1))" "$keytype" "${keycomment:-no comment}"
    done
    echo

    ask REMOVE_IDX "Remove key number (0 to cancel)" "0"
    if [[ "$REMOVE_IDX" == "0" ]]; then
      info "Cancelled."
      exit 0
    fi
    if [[ "$REMOVE_IDX" -ge 1 ]] && [[ "$REMOVE_IDX" -le "${#keys[@]}" ]]; then
      key_to_remove="${keys[$((REMOVE_IDX - 1))]}"
      tmp=$(mktemp)
      grep -vF "$key_to_remove" "$AUTH_KEYS" > "$tmp" || true
      mv "$tmp" "$AUTH_KEYS"
      chmod 600 "$AUTH_KEYS"
      success "Key removed from ${AUTH_KEYS}"
    else
      error "Invalid selection: ${REMOVE_IDX}"
      exit 1
    fi
    ;;
esac
