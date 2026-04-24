#!/usr/bin/env bash
# =============================================================================
#  Manage — Test Mail
#  Send a test email to verify SMTP / mail configuration.
#  Run standalone: sudo bash manage/test-mail.sh
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

section "Test Mail Configuration"

APP_PATH="$(creds_load APP_PATH 2> /dev/null || echo "")"
PHP_VERSION="$(creds_load PHP_VERSION 2> /dev/null || echo "8.4")"
APP_DOMAIN="$(creds_load APP_DOMAIN 2> /dev/null || echo "")"
MAILPIT_WEB_PORT="$(creds_load MAILPIT_WEB_PORT 2> /dev/null || echo "8025")"

ask APP_PATH "Laravel app path" "${APP_PATH:-/var/www/app/current}"
PHP_BIN="/usr/bin/php${PHP_VERSION}"
has_cmd "$PHP_BIN" || PHP_BIN="php"
ARTISAN="${APP_PATH}/artisan"

if [[ ! -f "$ARTISAN" ]]; then
  error "Artisan not found at ${ARTISAN}"
  exit 1
fi

ask_choice TEST_METHOD "How would you like to test mail?" \
  "Laravel artisan (via app mail config)" \
  "Raw SMTP connection test (no app needed)" \
  "Mailpit check (show received messages)"

case "$TEST_METHOD" in
  "Laravel"*)
    ask TO_EMAIL "Send test email to" "admin@${APP_DOMAIN:-example.com}"
    ask MAIL_SUBJECT "Subject" "LaraKit Test Email — $(date '+%Y-%m-%d %H:%M')"

    step "Sending test email via Laravel..."
    "$PHP_BIN" "$ARTISAN" tinker --execute "
      \$result = \Illuminate\Support\Facades\Mail::raw(
        'This is a LaraKit test email sent at ' . now()->toDateTimeString() . '.\n\nIf you received this, your mail configuration is working.',
        function(\$message) {
          \$message->to('${TO_EMAIL}')->subject('${MAIL_SUBJECT}');
        }
      );
      echo 'Mail dispatched.';
    " --no-interaction 2>&1 | tail -5

    success "Test email sent to ${TO_EMAIL}."

    if systemctl is-active --quiet mailpit 2> /dev/null; then
      info "Mailpit is running — check the inbox at:"
      echo -e "  ${DIM}http://localhost:${MAILPIT_WEB_PORT}${NC}"
      [[ -n "$APP_DOMAIN" ]] && echo -e "  ${DIM}http://$(creds_load MAILPIT_DOMAIN 2> /dev/null || echo "${APP_DOMAIN}")${NC}"
    fi
    ;;

  "Raw SMTP"*)
    ask SMTP_HOST "SMTP host" "127.0.0.1"
    ask SMTP_PORT "SMTP port" "$(creds_load MAILPIT_SMTP_PORT 2> /dev/null || echo "1025")"
    ask FROM_EMAIL "From address" "test@${APP_DOMAIN:-example.com}"
    ask TO_EMAIL "To address" "admin@${APP_DOMAIN:-example.com}"

    step "Testing raw SMTP connection to ${SMTP_HOST}:${SMTP_PORT}..."
    if ! has_cmd nc && ! has_cmd ncat; then
      pkg_install netcat-openbsd
    fi

    SMTP_TEST=$(printf "EHLO localhost\r\nQUIT\r\n" | nc -w 5 "$SMTP_HOST" "$SMTP_PORT" 2> /dev/null || echo "")
    if echo "$SMTP_TEST" | grep -q "220"; then
      success "SMTP server responded on ${SMTP_HOST}:${SMTP_PORT}"
      echo "$SMTP_TEST" | head -5 | sed 's/^/  /'
    else
      error "No SMTP response from ${SMTP_HOST}:${SMTP_PORT}"
      info "Check that your mail service is running and the port is correct."
    fi
    ;;

  "Mailpit"*)
    if ! systemctl is-active --quiet mailpit 2> /dev/null; then
      warn "Mailpit service is not running."
    else
      MESG_COUNT=$(curl -fsSL "http://127.0.0.1:${MAILPIT_WEB_PORT}/api/v1/messages" 2> /dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2> /dev/null || echo "?")
      info "Mailpit has ${MESG_COUNT} message(s) in inbox."
      info "Open in browser: http://127.0.0.1:${MAILPIT_WEB_PORT}"
      [[ -n "$(creds_load MAILPIT_DOMAIN 2> /dev/null)" ]] \
        && info "Or via Nginx: http://$(creds_load MAILPIT_DOMAIN)"
    fi
    ;;
esac
