#!/usr/bin/env bash
# =============================================================================
#  Module 31 — Headless Chromium
#  Installs Chromium + wkhtmltopdf for PDF generation and browser automation.
#  Run standalone: sudo bash modules/31-chromium.sh
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

module_header "Headless Chromium" "Chromium and wkhtmltopdf for PDF generation, screenshots, and browser automation."
require_root

ask_yn INSTALL_CHROMIUM "Install Chromium (headless browser — used by Browsershot, Puppeteer)?" "y"
ask_yn INSTALL_WKHTMLTOPDF "Install wkhtmltopdf (PDF generation — used by DomPDF, Snappy)?" "y"
ask_yn INSTALL_FONTS "Install common fonts (DejaVu, Liberation, CJK) to fix PDF rendering?" "y"

echo
confirm_or_exit "Install headless browser tools?"

# Chromium
if [[ "$INSTALL_CHROMIUM" == "true" ]]; then
  if has_cmd chromium-browser || has_cmd chromium || has_cmd google-chrome; then
    info "Chromium / Chrome already installed."
  else
    step "Installing Chromium..."
    pkg_install chromium-browser
    # On Ubuntu 22+, package may be chromium
    has_cmd chromium-browser || pkg_install chromium 2> /dev/null || warn "Could not install chromium — install manually."
    success "Chromium installed."
  fi

  # Resolve the binary
  CHROMIUM_BIN=""
  for b in chromium-browser chromium google-chrome; do
    has_cmd "$b" && CHROMIUM_BIN="$(command -v "$b")" && break
  done

  if [[ -n "$CHROMIUM_BIN" ]]; then
    CHROMIUM_VER=$("$CHROMIUM_BIN" --version 2> /dev/null | head -1 || echo "installed")
    success "Chromium: ${CHROMIUM_BIN} — ${CHROMIUM_VER}"
    creds_save "CHROMIUM_PATH" "$CHROMIUM_BIN"
  fi

  # Sandbox support (needed for headless in some environments)
  if ! grep -q "kernel.unprivileged_userns_clone" /etc/sysctl.d/99-laravel-tuning.conf 2> /dev/null; then
    echo "kernel.unprivileged_userns_clone = 1" >> /etc/sysctl.d/99-chromium.conf
    sysctl -p /etc/sysctl.d/99-chromium.conf > /dev/null 2>&1 || true
  fi
fi

# wkhtmltopdf
if [[ "$INSTALL_WKHTMLTOPDF" == "true" ]]; then
  if has_cmd wkhtmltopdf; then
    info "wkhtmltopdf already installed: $(wkhtmltopdf --version 2> /dev/null | head -1)"
  else
    step "Installing wkhtmltopdf..."
    # Try apt first
    pkg_install wkhtmltopdf 2> /dev/null || {
      # Fallback: download patched binary from GitHub
      warn "System wkhtmltopdf may lack patched Qt — downloading patched build..."
      ARCH=$(dpkg --print-architecture 2> /dev/null || echo "amd64")
      CODENAME=$(lsb_release -cs 2> /dev/null || echo "focal")
      WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.${CODENAME}_${ARCH}.deb"
      curl -fsSL "$WKHTML_URL" -o /tmp/wkhtmltox.deb 2> /dev/null \
        && DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/wkhtmltox.deb 2> /dev/null \
        && pkg_install -f 2> /dev/null \
        || warn "wkhtmltopdf install failed — install manually from https://wkhtmltopdf.org/downloads.html"
    }
    has_cmd wkhtmltopdf && success "wkhtmltopdf $(wkhtmltopdf --version 2> /dev/null | head -1)"
  fi

  WKHTMLTOPDF_BIN="$(command -v wkhtmltopdf 2> /dev/null || echo "")"
  [[ -n "$WKHTMLTOPDF_BIN" ]] && creds_save "WKHTMLTOPDF_PATH" "$WKHTMLTOPDF_BIN"
fi

# Fonts
if [[ "$INSTALL_FONTS" == "true" ]]; then
  step "Installing fonts for PDF rendering..."
  pkg_install \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-cjk \
    fontconfig \
    2> /dev/null || true
  fc-cache -f > /dev/null 2>&1 || true
  success "Fonts installed and cache refreshed."
fi

# Virtual display for non-headless usage (optional, no-op on servers)
if ! has_cmd Xvfb; then
  pkg_install xvfb 2> /dev/null || true
fi

creds_section "Headless Browser"

echo
success "Headless Chromium module complete."
info "Laravel package usage:"
dim "Browsershot (Spatie):     Browsershot::url('...')->save('page.pdf');"
dim "Laravel Snappy (wkhtml):  PDF::loadHTML(\$html)->inline();"
info "Verify Chromium headless:"
dim "chromium-browser --headless --disable-gpu --dump-dom https://example.com 2> /dev/null | head -5"
