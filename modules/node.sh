#!/usr/bin/env bash
# =============================================================================
#  Module 07 — Node.js & npm (via NVM)
#  Run standalone: sudo bash modules/07-node.sh
# =============================================================================
set -euo pipefail

if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  # Source config for SETUP_BASE_URL
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

module_header "Node.js & npm" "Installs Node.js via NVM for building frontend assets."
require_root

# Version selection
ask_choice NODE_VERSION "Select Node.js version:" \
  "24 (Current — 2025)" \
  "22 (LTS — recommended)" \
  "20 (LTS — previous)" \
  "18 (LTS — maintenance)"

NODE_VERSION="${NODE_VERSION%% *}"

# Install for which users
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "")"
ask INSTALL_FOR_USER "Install NVM for which user (or 'root')" "${DEPLOY_USER:-root}"

ask_yn INSTALL_YARN "Install Yarn (classic) globally?" "n"
ask_yn INSTALL_PNPM "Install pnpm globally?" "n"
ask_yn INSTALL_BUN "Install Bun (fast Node alternative)?" "n"

echo
confirm_or_exit "Install Node.js ${NODE_VERSION} via NVM?"

# NVM installation
NVM_VERSION="0.40.1"

install_nvm_for_user() {
  local target_user="$1"
  local home_dir
  if [[ "$target_user" == "root" ]]; then
    home_dir="/root"
  else
    home_dir="/home/${target_user}"
  fi

  step "Installing NVM for user '${target_user}'..."
  su - "$target_user" -c "
    export NVM_DIR=\"\${HOME}/.nvm\"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh | bash
    export NVM_DIR=\"\${HOME}/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    nvm install ${NODE_VERSION}
    nvm alias default ${NODE_VERSION}
    nvm use default
    node -v && npm -v
  " 2>&1 | tail -5

  # Add NVM to system profile for non-interactive shells
  local profile="${home_dir}/.bashrc"
  ensure_line 'export NVM_DIR="$HOME/.nvm"' "$profile"
  ensure_line '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' "$profile"
  ensure_line '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' "$profile"

  success "NVM + Node.js ${NODE_VERSION} installed for ${target_user}."
}

install_nvm_for_user "$INSTALL_FOR_USER"

# Also install for root if deploying as different user
if [[ "$INSTALL_FOR_USER" != "root" ]]; then
  ask_yn INSTALL_FOR_ROOT "Also install NVM for root?" "y"
  [[ "$INSTALL_FOR_ROOT" == "true" ]] && install_nvm_for_user "root"
fi

# Global packages
run_as_user() {
  su - "$INSTALL_FOR_USER" -c "
    export NVM_DIR=\"\$HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    $*
  " 2> /dev/null
}

if [[ "$INSTALL_YARN" == "true" ]]; then
  step "Installing Yarn..."
  run_as_user "npm install -g yarn" && success "Yarn installed."
fi

if [[ "$INSTALL_PNPM" == "true" ]]; then
  step "Installing pnpm..."
  run_as_user "npm install -g pnpm" && success "pnpm installed."
fi

if [[ "$INSTALL_BUN" == "true" ]]; then
  step "Installing Bun..."
  su - "$INSTALL_FOR_USER" -c "curl -fsSL https://bun.sh/install | bash" > /dev/null 2>&1
  success "Bun installed."
fi

# Save
creds_section "Node.js"
creds_save "NODE_VERSION" "$NODE_VERSION"
creds_save "NODE_INSTALL_USER" "$INSTALL_FOR_USER"
creds_save "NVM_VERSION" "$NVM_VERSION"

echo
success "Node.js module complete."
info "To use Node.js in scripts, source NVM first:"
dim "source ~/.nvm/nvm.sh && node -v"
