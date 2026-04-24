#!/usr/bin/env bash
# =============================================================================
#  LaraKit Uninstaller
#  Removes the LaraKit CLI and all installed scripts from this machine.
#  Does NOT remove software installed BY LaraKit (PHP, Nginx, databases, etc.)
#
#  Usage (local):   sudo bash uninstall.sh
#  Usage (remote):  sudo bash <(curl -fsSL https://raw.githubusercontent.com/iamolayemi/larakit/main/uninstall.sh)
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/larakit"
BIN_PATH="/usr/local/bin/larakit"
BASH_COMPLETION="/etc/bash_completion.d/larakit"
ZSH_COMPLETION="/usr/local/share/zsh/site-functions/_larakit"
CREDS_FILE="$HOME/.larakit-creds"

step() { echo -e "\n  \033[34m→\033[0m  $*"; }
success() { echo -e "  \033[32m✔\033[0m  $*"; }
warn() { echo -e "  \033[33m⚠\033[0m  $*"; }
error() { echo -e "  \033[31m✘\033[0m  $*" >&2; }
info() { echo -e "  \033[36m·\033[0m  $*"; }
bold() { echo -e "  \033[1m$*\033[0m"; }
divider() { echo -e "  \033[2m──────────────────────────────────────────────────\033[0m"; }

if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root: sudo bash uninstall.sh"
  exit 1
fi

echo
bold "LaraKit Uninstaller"
divider
echo
info "This will remove the LaraKit CLI and all scripts from this server."
info "It will NOT remove software installed BY LaraKit (PHP, Nginx, MySQL, etc.)"
echo

# Show what will be removed
echo -e "  \033[1mWill remove:\033[0m"
[[ -f "$BIN_PATH" ]] && echo -e "    • ${BIN_PATH}"
[[ -d "$INSTALL_DIR" ]] && echo -e "    • ${INSTALL_DIR}"
[[ -f "$BASH_COMPLETION" ]] && echo -e "    • ${BASH_COMPLETION}"
[[ -f "$ZSH_COMPLETION" ]] && echo -e "    • ${ZSH_COMPLETION}"

echo
echo -e "  \033[1mWill keep (your data):\033[0m"
echo -e "    • ${CREDS_FILE}  (and any ~/.larakit-creds.*)"
echo -e "    • All software installed by LaraKit (PHP, Nginx, MySQL, etc.)"
echo -e "    • All application files and databases"
echo

# Confirm
printf "  \033[33m?\033[0m  Type 'yes' to confirm uninstall: "
read -r CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo -e "\n  Uninstall cancelled.\n"
  exit 0
fi

echo

# ---- Remove binary ----------------------------------------------------------
if [[ -f "$BIN_PATH" ]]; then
  step "Removing ${BIN_PATH}..."
  rm -f "$BIN_PATH"
  success "Binary removed."
fi

# ---- Remove install directory -----------------------------------------------
if [[ -d "$INSTALL_DIR" ]]; then
  step "Removing ${INSTALL_DIR}..."
  rm -rf "$INSTALL_DIR"
  success "Install directory removed."
fi

# ---- Remove shell completions -----------------------------------------------
if [[ -f "$BASH_COMPLETION" ]]; then
  step "Removing bash completion..."
  rm -f "$BASH_COMPLETION"
  success "Bash completion removed."
fi

if [[ -f "$ZSH_COMPLETION" ]]; then
  step "Removing zsh completion..."
  rm -f "$ZSH_COMPLETION"
  success "Zsh completion removed."
fi

# ---- Optional: remove credentials ------------------------------------------
echo
CRED_FILES=()
[[ -f "$CREDS_FILE" ]] && CRED_FILES+=("$CREDS_FILE")
for f in "$HOME"/.larakit-creds.*; do
  [[ -f "$f" ]] && CRED_FILES+=("$f")
done

if [[ ${#CRED_FILES[@]} -gt 0 ]]; then
  warn "Credential files found:"
  for f in "${CRED_FILES[@]}"; do
    echo -e "    • ${f}"
  done
  echo
  printf "  \033[33m?\033[0m  Delete credential files too? [y/N]: "
  read -r DEL_CREDS
  if [[ "${DEL_CREDS,,}" == "y" || "${DEL_CREDS,,}" == "yes" ]]; then
    for f in "${CRED_FILES[@]}"; do
      rm -f "$f"
      success "Removed: ${f}"
    done
    warn "Make sure you have saved your credentials elsewhere before deleting."
  else
    info "Credentials kept at:"
    for f in "${CRED_FILES[@]}"; do
      echo -e "    • ${f}"
    done
  fi
fi

echo
echo -e "  \033[1;32m✔  LaraKit uninstalled successfully.\033[0m"
echo
info "To reinstall: sudo bash <(curl -fsSL https://raw.githubusercontent.com/iamolayemi/larakit/main/install.sh)"
echo
