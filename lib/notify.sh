#!/usr/bin/env bash
# LaraKit — Deployment notification helpers (Slack, Telegram, Discord)

# notify_deploy <event> <message>
# event: start | success | failure
# Reads SLACK_WEBHOOK_URL, TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID, DISCORD_WEBHOOK_URL
# from the credentials file. Silently skips if none are configured.
notify_deploy() {
  local event="${1:-info}" message="${2:-}"
  local app_domain
  app_domain=$(creds_load APP_DOMAIN 2> /dev/null || echo "")
  local server_ip
  server_ip=$(creds_load SERVER_IP 2> /dev/null || hostname -I 2> /dev/null | awk '{print $1}')
  local host="${app_domain:-${server_ip}}"

  local slack_url
  slack_url=$(creds_load SLACK_WEBHOOK_URL 2> /dev/null || echo "")
  local tg_token
  tg_token=$(creds_load TELEGRAM_BOT_TOKEN 2> /dev/null || echo "")
  local tg_chat
  tg_chat=$(creds_load TELEGRAM_CHAT_ID 2> /dev/null || echo "")
  local discord_url
  discord_url=$(creds_load DISCORD_WEBHOOK_URL 2> /dev/null || echo "")

  local icon
  case "$event" in
    start) icon="🚀" ;;
    success) icon="✅" ;;
    failure) icon="❌" ;;
    *) icon="ℹ️" ;;
  esac

  local full_msg="${icon} [${host}] ${message}"

  if [[ -n "$slack_url" ]]; then
    local payload
    printf -v payload '{"text":"%s"}' "${full_msg//\"/\\\"}"
    curl -s -X POST -H 'Content-type: application/json' \
      --data "$payload" "$slack_url" &> /dev/null || true
  fi

  if [[ -n "$tg_token" && -n "$tg_chat" ]]; then
    curl -s "https://api.telegram.org/bot${tg_token}/sendMessage" \
      -d "chat_id=${tg_chat}" \
      -d "text=${full_msg}" \
      -d "parse_mode=HTML" &> /dev/null || true
  fi

  if [[ -n "$discord_url" ]]; then
    local payload
    printf -v payload '{"content":"%s"}' "${full_msg//\"/\\\"}"
    curl -s -X POST -H 'Content-type: application/json' \
      --data "$payload" "$discord_url" &> /dev/null || true
  fi
}

# notify_configure — interactively set notification webhooks
notify_configure() {
  section "Notification Webhooks"
  echo -e "  ${DIM}Leave blank to skip a channel.${NC}\n"

  local slack_url tg_token tg_chat discord_url
  ask slack_url "Slack Webhook URL" "$(creds_load SLACK_WEBHOOK_URL 2> /dev/null || echo "")"
  ask tg_token "Telegram Bot Token" "$(creds_load TELEGRAM_BOT_TOKEN 2> /dev/null || echo "")"
  ask tg_chat "Telegram Chat ID" "$(creds_load TELEGRAM_CHAT_ID 2> /dev/null || echo "")"
  ask discord_url "Discord Webhook URL" "$(creds_load DISCORD_WEBHOOK_URL 2> /dev/null || echo "")"

  [[ -n "$slack_url" ]] && creds_save SLACK_WEBHOOK_URL "$slack_url"
  [[ -n "$tg_token" ]] && creds_save TELEGRAM_BOT_TOKEN "$tg_token"
  [[ -n "$tg_chat" ]] && creds_save TELEGRAM_CHAT_ID "$tg_chat"
  [[ -n "$discord_url" ]] && creds_save DISCORD_WEBHOOK_URL "$discord_url"

  success "Notification settings saved."
}
