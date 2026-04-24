#!/usr/bin/env bash
# =============================================================================
#  Manage — Webhook Listen
#  Set up a GitHub/GitLab webhook listener for auto-deployments.
#  Run standalone: sudo bash manage/webhook-listen.sh
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

section "Webhook Deploy Listener"
require_root

info "Creates a PHP webhook endpoint that GitHub/GitLab calls on push events."
info "Incoming webhooks trigger your deploy.sh script automatically."
echo

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "/var/www/app/current")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
DEPLOY_USER="$(creds_load DEPLOY_USER 2> /dev/null || echo "deploy")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"

ask APP_DOMAIN "Domain where webhook lives" "${APP_DOMAIN}"
ask WEBHOOK_PORT "Webhook listener port" "9001"
ask WEBHOOK_PATH "Webhook URL path" "/webhook/deploy"
WEBHOOK_SECRET=$(creds_load WEBHOOK_SECRET 2> /dev/null || gen_secret 32)
ask_secret SECRET_INPUT "Webhook secret (blank to use generated)"
[[ -n "$SECRET_INPUT" ]] && WEBHOOK_SECRET="$SECRET_INPUT"

WEBHOOK_DIR="/var/www/webhook"
WEBHOOK_LOG="/var/log/webhook-deploy.log"
DEPLOY_SCRIPT="/usr/local/bin/larakit-deploy"

step "Writing webhook handler script..."
mkdir -p "$WEBHOOK_DIR"

cat > "${WEBHOOK_DIR}/index.php" << PHPEOF
<?php
// LaraKit Webhook Deploy Handler
define('WEBHOOK_SECRET', '${WEBHOOK_SECRET}');
define('DEPLOY_SCRIPT', '${DEPLOY_SCRIPT}');
define('LOG_FILE', '${WEBHOOK_LOG}');

function log_msg(string \$msg): void {
    \$line = '[' . date('Y-m-d H:i:s') . '] ' . \$msg . PHP_EOL;
    file_put_contents(LOG_FILE, \$line, FILE_APPEND | LOCK_EX);
}

function respond(int \$code, string \$body): void {
    http_response_code(\$code);
    header('Content-Type: application/json');
    echo json_encode(['message' => \$body]);
    exit;
}

// Only accept POST
if (\$_SERVER['REQUEST_METHOD'] !== 'POST') {
    respond(405, 'Method not allowed');
}

\$payload = file_get_contents('php://input');
\$signature = \$_SERVER['HTTP_X_HUB_SIGNATURE_256']    // GitHub
           ?? \$_SERVER['HTTP_X_GITLAB_TOKEN']           // GitLab token header
           ?? '';

// GitHub signature verification
if (isset(\$_SERVER['HTTP_X_HUB_SIGNATURE_256'])) {
    \$expected = 'sha256=' . hash_hmac('sha256', \$payload, WEBHOOK_SECRET);
    if (!hash_equals(\$expected, \$signature)) {
        log_msg('REJECTED: invalid GitHub signature from ' . (\$_SERVER['REMOTE_ADDR'] ?? '?'));
        respond(403, 'Invalid signature');
    }
} elseif (isset(\$_SERVER['HTTP_X_GITLAB_TOKEN'])) {
    // GitLab: token in header must match secret
    if (\$signature !== WEBHOOK_SECRET) {
        log_msg('REJECTED: invalid GitLab token from ' . (\$_SERVER['REMOTE_ADDR'] ?? '?'));
        respond(403, 'Invalid token');
    }
} else {
    respond(403, 'No auth header');
}

\$data = json_decode(\$payload, true) ?? [];
\$ref  = \$data['ref'] ?? \$data['object_attributes']['ref'] ?? 'unknown';
\$who  = \$data['pusher']['name'] ?? \$data['user_name'] ?? 'unknown';

log_msg("DEPLOY triggered — ref: {\$ref}, pusher: {\$who}");

// Run deploy in background so webhook returns immediately
\$cmd = 'sudo bash ' . escapeshellarg(DEPLOY_SCRIPT) . ' >> ' . LOG_FILE . ' 2>&1 &';
exec(\$cmd);

respond(200, 'Deploy triggered');
PHPEOF

step "Writing deploy runner script..."
cat > "$DEPLOY_SCRIPT" << BASHEOF
#!/usr/bin/env bash
# Triggered by webhook — runs a non-interactive quick deploy
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

APP_PATH="${APP_PATH}"
PHP_BIN="/usr/bin/php${PHP_VERSION}"
DEPLOY_USER="${DEPLOY_USER}"

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Webhook deploy started"

sudo -u "\$DEPLOY_USER" git -C "\$APP_PATH" fetch --all
sudo -u "\$DEPLOY_USER" git -C "\$APP_PATH" reset --hard origin/\$(git -C "\$APP_PATH" rev-parse --abbrev-ref HEAD)
sudo -u "\$DEPLOY_USER" composer install --working-dir="\$APP_PATH" --no-dev --optimize-autoloader --no-interaction --quiet
sudo -u "\$DEPLOY_USER" "\$PHP_BIN" "\${APP_PATH}/artisan" migrate --force --no-interaction
sudo -u "\$DEPLOY_USER" "\$PHP_BIN" "\${APP_PATH}/artisan" config:cache --no-interaction
sudo -u "\$DEPLOY_USER" "\$PHP_BIN" "\${APP_PATH}/artisan" route:cache --no-interaction
sudo -u "\$DEPLOY_USER" "\$PHP_BIN" "\${APP_PATH}/artisan" view:cache --no-interaction
systemctl reload "php${PHP_VERSION}-fpm" 2> /dev/null || true
supervisorctl restart "laravel-worker:*" 2> /dev/null || true

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Webhook deploy complete"
BASHEOF
chmod +x "$DEPLOY_SCRIPT"

# sudoers entry so www-data can run deploy script
SUDOERS_ENTRY="www-data ALL=(root) NOPASSWD: /bin/bash ${DEPLOY_SCRIPT}"
if ! grep -qF "$DEPLOY_SCRIPT" /etc/sudoers.d/webhook-deploy 2> /dev/null; then
  echo "$SUDOERS_ENTRY" > /etc/sudoers.d/webhook-deploy
  chmod 440 /etc/sudoers.d/webhook-deploy
fi

# Touch log file
touch "$WEBHOOK_LOG"
chown www-data:www-data "$WEBHOOK_LOG"
chown -R www-data:www-data "$WEBHOOK_DIR"

step "Writing Nginx server block for webhook..."
if has_cmd nginx; then
  cat > /etc/nginx/sites-available/webhook << NGINXEOF
server {
    listen ${WEBHOOK_PORT};
    server_name _;

    root ${WEBHOOK_DIR};
    index index.php;

    location ${WEBHOOK_PATH} {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location / {
        return 403;
    }
}
NGINXEOF
  ln -sf /etc/nginx/sites-available/webhook /etc/nginx/sites-enabled/webhook
  nginx -t && systemctl reload nginx
  add_firewall_rule "$WEBHOOK_PORT" tcp 2> /dev/null || true
  success "Nginx webhook endpoint configured on :${WEBHOOK_PORT}${WEBHOOK_PATH}"
fi

creds_section "Webhook"
creds_save "WEBHOOK_SECRET" "$WEBHOOK_SECRET"
creds_save "WEBHOOK_PORT" "$WEBHOOK_PORT"
creds_save "WEBHOOK_PATH" "$WEBHOOK_PATH"
creds_save "WEBHOOK_LOG" "$WEBHOOK_LOG"

WEBHOOK_URL="http://${APP_DOMAIN}:${WEBHOOK_PORT}${WEBHOOK_PATH}"
echo
success "Webhook listener ready."
echo
info "Add this webhook in GitHub:"
echo -e "  ${DIM}Payload URL:  ${WEBHOOK_URL}"
echo -e "  Content type: application/json"
echo -e "  Secret:       ${WEBHOOK_SECRET}"
echo -e "  Event:        Just the push event${NC}"
echo
info "Or in GitLab (Settings → Webhooks):"
echo -e "  ${DIM}URL:          ${WEBHOOK_URL}"
echo -e "  Secret token: ${WEBHOOK_SECRET}"
echo -e "  Trigger:      Push events${NC}"
echo
info "Watch deploy logs:"
echo -e "  ${DIM}tail -f ${WEBHOOK_LOG}${NC}"
