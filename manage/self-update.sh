#!/usr/bin/env bash
# =============================================================================
#  Manage — Self Update
#  Pull the latest LaraKit scripts from GitHub.
#  Run standalone: sudo bash manage/self-update.sh
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

section "Self-Update LaraKit"

# Detect installation dir (where setup.sh lives)
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SETUP_SH="${INSTALL_DIR}/setup.sh"
MANAGE_SH="${INSTALL_DIR}/manage.sh"

info "Updating from: ${SETUP_BASE_URL}"
info "Install dir:   ${INSTALL_DIR}"
echo

if [[ ! -f "$SETUP_SH" ]]; then
  error "Could not locate setup.sh in ${INSTALL_DIR}. Is this a local installation?"
  info "For remote-only runs, re-run the original curl command to get the latest version."
  exit 1
fi

ask_yn DO_UPDATE "Download latest scripts from GitHub?" "y"
[[ "$DO_UPDATE" != "true" ]] && {
  info "Aborted."
  exit 0
}

UPDATED=0
FAILED=0

update_file() {
  local rel="$1"
  local dest="${INSTALL_DIR}/${rel}"
  local url="${SETUP_BASE_URL}/${rel}"
  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  if curl -fsSL --max-time 15 "$url" -o "${dest}.tmp" 2> /dev/null; then
    if bash -n "${dest}.tmp" 2> /dev/null; then
      [[ -f "$dest" ]] && backup_file "$dest"
      mv "${dest}.tmp" "$dest"
      chmod +x "$dest"
      printf "  ${GREEN}✔${NC}  %s\n" "$rel"
      UPDATED=$((UPDATED + 1))
    else
      rm -f "${dest}.tmp"
      printf "  ${RED}✘${NC}  %s (syntax error in downloaded file — skipped)\n" "$rel"
      FAILED=$((FAILED + 1))
    fi
  else
    rm -f "${dest}.tmp"
    printf "  ${YELLOW}!${NC}  %s (not found at ${url})\n" "$rel"
  fi
}

step "Updating core files..."
update_file "setup.sh"
update_file "manage.sh"
update_file "config.sh"

step "Updating libraries..."
for f in colors.sh prompts.sh creds.sh utils.sh; do
  update_file "lib/${f}"
done

step "Updating modules..."
for f in "${INSTALL_DIR}"/modules/*.sh; do
  [[ -f "$f" ]] && update_file "modules/$(basename "$f")"
done

step "Updating management scripts..."
for f in "${INSTALL_DIR}"/manage/*.sh; do
  [[ -f "$f" ]] && update_file "manage/$(basename "$f")"
done

echo
divider
printf "  Updated: ${GREEN}%d${NC}  Failed: ${RED}%d${NC}\n\n" "$UPDATED" "$FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  warn "Some files could not be updated. Check your SETUP_BASE_URL and network access."
fi

success "LaraKit updated. Backup .bak files saved next to changed files."
info "To clean up backups: find ${INSTALL_DIR} -name '*.bak.*' -delete"
