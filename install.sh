#!/usr/bin/env bash
# =============================================================================
#  LaraKit CLI Installer
#  Installs the 'larakit' command to /usr/local/bin and copies scripts to
#  /opt/larakit so you can run: larakit install php, larakit manage deploy, etc.
#
#  Usage (local):
#    sudo bash install.sh
#
#  Usage (remote):
#    sudo bash <(curl -fsSL https://raw.githubusercontent.com/iamolayemi/larakit/main/install.sh)
# =============================================================================
set -euo pipefail

INSTALL_DIR="/opt/larakit"
BIN_PATH="/usr/local/bin/larakit"
COMPLETION_PATH="/etc/bash_completion.d/larakit"

# Resolve whether we're running locally or from a remote pipe
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  IS_LOCAL=true
else
  SCRIPT_DIR=""
  IS_LOCAL=false
fi

# Need SETUP_BASE_URL for remote installs — source config.sh if present
if [[ "$IS_LOCAL" == "true" ]] && [[ -f "${SCRIPT_DIR}/config.sh" ]]; then
  source "${SCRIPT_DIR}/config.sh"
fi
: "${SETUP_BASE_URL:?ERROR: SETUP_BASE_URL is not set. Export it or clone the repo locally.}"

step() { echo -e "\n  \033[34m→\033[0m  $*"; }
success() { echo -e "  \033[32m✔\033[0m  $*"; }
error() { echo -e "  \033[31m✘\033[0m  $*" >&2; }
info() { echo -e "  \033[36m·\033[0m  $*"; }

if [[ "$EUID" -ne 0 ]]; then
  error "Please run as root: sudo bash install.sh"
  exit 1
fi

echo
echo "  \033[1mLaraKit CLI Installer\033[0m"
echo "  Installing to: ${INSTALL_DIR}"
echo "  Binary:        ${BIN_PATH}"
echo

step "Creating ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/modules" "${INSTALL_DIR}/manage" "${INSTALL_DIR}/completions"

install_file() {
  local rel="$1"
  local dest="${INSTALL_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"

  if [[ "$IS_LOCAL" == "true" ]] && [[ -f "${SCRIPT_DIR}/${rel}" ]]; then
    cp "${SCRIPT_DIR}/${rel}" "$dest"
  else
    curl -fsSL "${SETUP_BASE_URL}/${rel}" -o "$dest"
  fi
  chmod +x "$dest"
}

step "Installing core files..."
for f in config.sh setup.sh manage.sh larakit; do
  install_file "$f"
  success "$f"
done

step "Installing libraries..."
for f in colors.sh prompts.sh creds.sh utils.sh; do
  install_file "lib/${f}"
  success "lib/${f}"
done

step "Installing modules..."
MODULES=(
  00-preflight.sh 01-system-init.sh 02-server-hardening.sh
  03-php.sh 04-nginx.sh 05-mysql.sh 06-redis.sh 07-node.sh 08-ssl.sh
  09-laravel-app.sh 10-queue-worker.sh 11-scheduler.sh
  12-horizon.sh 13-reverb.sh 14-octane.sh 15-minio.sh 16-postgres.sh
  17-meilisearch.sh 18-typesense.sh 19-elasticsearch.sh 20-rabbitmq.sh
  21-varnish.sh 22-load-balancer.sh 23-mailpit.sh 24-backups.sh
  25-tuning.sh 26-monitoring.sh 27-phpmyadmin.sh 28-pgadmin.sh
  29-soketi.sh 30-memcached.sh 31-chromium.sh
)
for f in "${MODULES[@]}"; do
  install_file "modules/${f}"
  success "modules/${f}"
done

step "Installing management scripts..."
MANAGE=(
  health.sh report.sh deploy.sh redeploy.sh rollback.sh restart.sh
  logs.sh db-backup.sh db-restore.sh ssl-renew.sh
  queue-status.sh test-mail.sh generate-env.sh webhook-listen.sh
  self-update.sh credentials.sh firewall-audit.sh init.sh
  db-optimize.sh performance-test.sh diagnose.sh env-check.sh
  ssh-keys.sh swap.sh crontab.sh php-ext.sh
  db-copy.sh logrotate.sh queue-scale.sh
  cache-clear.sh ssl-info.sh app-create.sh
)
for f in "${MANAGE[@]}"; do
  install_file "manage/${f}"
  success "manage/${f}"
done

step "Installing shell completions..."
install_file "completions/larakit.bash"
install_file "completions/larakit.zsh"
success "completions/larakit.bash"
success "completions/larakit.zsh"

step "Installing larakit binary to ${BIN_PATH}..."
cp "${INSTALL_DIR}/larakit" "$BIN_PATH"
chmod +x "$BIN_PATH"

# Bake LARAKIT_HOME into the binary so it always resolves correctly
tmp=$(mktemp)
sed "s|LARAKIT_HOME=\"\${LARAKIT_HOME:-/opt/larakit}\"|LARAKIT_HOME=\"\${LARAKIT_HOME:-${INSTALL_DIR}}\"|" "$BIN_PATH" > "$tmp" && mv "$tmp" "$BIN_PATH" || true
chmod +x "$BIN_PATH"

success "larakit installed at ${BIN_PATH}"

step "Installing bash completion..."
cp "${INSTALL_DIR}/completions/larakit.bash" "$COMPLETION_PATH"
chmod 644 "$COMPLETION_PATH"
success "Bash completion installed at ${COMPLETION_PATH}"

# Zsh completion (if zsh is present)
if has_cmd zsh 2> /dev/null || command -v zsh &> /dev/null; then
  ZSH_FPATH_DIR="/usr/local/share/zsh/site-functions"
  mkdir -p "$ZSH_FPATH_DIR"
  cp "${INSTALL_DIR}/completions/larakit.zsh" "${ZSH_FPATH_DIR}/_larakit"
  chmod 644 "${ZSH_FPATH_DIR}/_larakit"
  success "Zsh completion installed at ${ZSH_FPATH_DIR}/_larakit"
fi

echo
echo "  \033[1;32m✔  LaraKit CLI installed successfully.\033[0m"
echo
info "Reload your shell or run:  source ${COMPLETION_PATH}"
echo
echo "  \033[1mTry it:\033[0m"
echo "    larakit help"
echo "    larakit list"
echo "    larakit install php"
echo "    larakit manage health"
echo "    larakit setup"
echo
