#!/usr/bin/env bash

# Multi-app: LARAKIT_APP=myapp → ~/.larakit-creds.myapp
# LARAKIT_APP always wins over a pre-set CREDS_FILE (e.g. from config.sh).
if [[ -n "${LARAKIT_APP:-}" ]]; then
  CREDS_FILE="${HOME}/.larakit-creds.${LARAKIT_APP}"
else
  CREDS_FILE="${CREDS_FILE:-$HOME/.larakit-creds}"
fi

creds_init() {
  if [[ ! -f "$CREDS_FILE" ]]; then
    cat > "$CREDS_FILE" << EOF
# ============================================================
#  LaraKit - Credentials
#  Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================
# ⚠  IMPORTANT: Secure and delete this file after setup!
#    rm "$CREDS_FILE"
# ============================================================

EOF
    chmod 600 "$CREDS_FILE"
  fi
}

# creds_save <KEY> <VALUE>
creds_save() {
  local key="$1" value="$2"
  creds_init
  # Remove existing entry then append (portable: avoids sed -i '' macOS vs Linux diff)
  local tmp
  tmp=$(mktemp)
  grep -v "^${key}=" "$CREDS_FILE" > "$tmp" || true
  mv "$tmp" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  echo "${key}=${value}" >> "$CREDS_FILE"
}

# creds_load <KEY>
creds_load() {
  local key="$1"
  if [[ -f "$CREDS_FILE" ]]; then
    grep "^${key}=" "$CREDS_FILE" | cut -d'=' -f2-
  fi
}

# creds_section <LABEL>
creds_section() {
  local label="$1"
  creds_init
  echo "" >> "$CREDS_FILE"
  echo "# --- ${label} ---" >> "$CREDS_FILE"
}

creds_show() {
  section "Stored Credentials"
  if [[ ! -f "$CREDS_FILE" ]]; then
    info "No credentials stored yet."
    return
  fi

  echo -e "  ${DIM}File: ${CREDS_FILE}${NC}\n"
  divider

  local in_section=false
  while IFS='=' read -r key rest; do
    if [[ "$key" =~ ^#\ ---\ (.+)\ ---$ ]]; then
      echo -e "\n  ${MAGENTA}${BOLD}${BASH_REMATCH[1]}${NC}"
    elif [[ "$key" =~ ^#.*$ ]] || [[ -z "$key" ]]; then
      continue
    else
      printf "  ${BOLD}%-35s${NC} ${GREEN}%s${NC}\n" "$key" "$rest"
    fi
  done < "$CREDS_FILE"

  divider
  echo
  warn "Delete this file after securing your credentials:"
  echo -e "  ${DIM}rm ${CREDS_FILE}${NC}"
  echo
}

# gen_password [length]  — includes symbols
gen_password() {
  local length="${1:-24}"
  tr -dc 'A-Za-z0-9!@#%^&*_+=' < /dev/urandom | head -c "$length"
  echo
}

# gen_secret [length]  — alphanumeric only (safe for configs)
gen_secret() {
  local length="${1:-32}"
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
  echo
}
