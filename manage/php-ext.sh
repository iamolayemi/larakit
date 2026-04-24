#!/usr/bin/env bash
# =============================================================================
#  Manage — PHP Extensions
#  Enable or disable PHP extensions interactively.
#  Run standalone: sudo bash manage/php-ext.sh
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

module_header "PHP Extensions" "Enable or disable PHP extensions for the active PHP version."
require_root

PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
ask PHP_VER "PHP version to manage" "$PHP_VERSION"

# Validate PHP is installed
if ! has_cmd "php${PHP_VER}"; then
  error "PHP ${PHP_VER} not found. Install it first: larakit install php"
  exit 1
fi

ask_choice EXT_ACTION "Action:" \
  "list    — show all loaded extensions" \
  "enable  — enable an extension" \
  "disable — disable an extension" \
  "install — install a new extension package"
EXT_ACTION="${EXT_ACTION%% *}"

case "$EXT_ACTION" in
  list)
    section "PHP ${PHP_VER} Loaded Extensions"
    php"${PHP_VER}" -m | sort | while IFS= read -r ext; do
      [[ "$ext" =~ ^\[ ]] && echo -e "\n  ${MAGENTA}${BOLD}${ext}${NC}" && continue
      printf "  ${GREEN}✔${NC} %s\n" "$ext"
    done
    echo
    total=$(php"${PHP_VER}" -m | grep -vc '^\[' || true)
    info "${total} extensions loaded."
    ;;

  enable)
    section "Enable PHP ${PHP_VER} Extension"
    # List available (installed but possibly disabled) extensions
    available_dir="/etc/php/${PHP_VER}/mods-available"
    if [[ -d "$available_dir" ]]; then
      echo -e "  ${DIM}Available extensions in ${available_dir}:${NC}\n"
      ls "$available_dir" | sed 's/\.ini$//' | xargs -I{} printf "  %s\n" {} | column
      echo
    fi
    ask EXT_NAME "Extension name (e.g. xdebug, imagick, redis)" ""
    [[ -z "$EXT_NAME" ]] && {
      error "Extension name cannot be empty."
      exit 1
    }

    step "Enabling php${PHP_VER}-${EXT_NAME}..."
    if run_or_dry phpenmod -v "$PHP_VER" "$EXT_NAME"; then
      step "Restarting PHP-FPM..."
      run_or_dry systemctl restart "php${PHP_VER}-fpm" 2> /dev/null || true
      success "Extension '${EXT_NAME}' enabled for PHP ${PHP_VER}."
      php"${PHP_VER}" -m | grep -i "$EXT_NAME" && true
    else
      error "Failed to enable '${EXT_NAME}'. Is it installed?"
      info "Install it with: larakit manage php-ext (choose 'install')"
    fi
    ;;

  disable)
    section "Disable PHP ${PHP_VER} Extension"
    ask EXT_NAME "Extension name to disable" ""
    [[ -z "$EXT_NAME" ]] && {
      error "Extension name cannot be empty."
      exit 1
    }

    step "Disabling php${PHP_VER}-${EXT_NAME}..."
    if run_or_dry phpdismod -v "$PHP_VER" "$EXT_NAME"; then
      step "Restarting PHP-FPM..."
      run_or_dry systemctl restart "php${PHP_VER}-fpm" 2> /dev/null || true
      success "Extension '${EXT_NAME}' disabled for PHP ${PHP_VER}."
    else
      error "Failed to disable '${EXT_NAME}'."
    fi
    ;;

  install)
    section "Install PHP ${PHP_VER} Extension Package"
    echo -e "  ${DIM}Common extensions: xdebug, imagick, gmp, imap, ldap, sodium, tidy${NC}\n"
    ask EXT_NAME "Extension to install" ""
    [[ -z "$EXT_NAME" ]] && {
      error "Extension name cannot be empty."
      exit 1
    }

    pkg="php${PHP_VER}-${EXT_NAME}"
    step "Installing ${pkg}..."
    if run_or_dry pkg_install "$pkg"; then
      step "Enabling extension..."
      run_or_dry phpenmod -v "$PHP_VER" "$EXT_NAME" 2> /dev/null || true
      step "Restarting PHP-FPM..."
      run_or_dry systemctl restart "php${PHP_VER}-fpm" 2> /dev/null || true
      success "Extension '${EXT_NAME}' installed and enabled for PHP ${PHP_VER}."
    else
      error "Package ${pkg} not found. Check the extension name and try again."
    fi
    ;;
esac
