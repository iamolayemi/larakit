#!/usr/bin/env bash
# =============================================================================
#  LaraKit — Bash completion
#  Install: source this file, or place in /etc/bash_completion.d/larakit
# =============================================================================

_larakit_modules=(
  preflight pre-flight 0 00
  system init sysint 1 01
  hardening security 2 02
  php 3 03
  nginx 4 04
  mysql mariadb db 5 05
  redis 6 06
  node nodejs npm 7 07
  ssl tls certbot 8 08
  app laravel 9 09
  queue worker 10
  scheduler cron 11
  horizon 12
  reverb websocket ws 13
  octane 14
  minio s3 15
  postgres postgresql pg 16
  meilisearch search meili 17
  typesense ts 18
  elasticsearch elastic es 19
  rabbitmq rabbit mq 20
  varnish 21
  lb loadbalancer haproxy 22
  mailpit mail 23
  backups backup 24
  tuning tune 25
  monitoring monitor 26
  phpmyadmin pma 27
  pgadmin 28
  soketi pusher 29
  memcached memcache 30
  chromium chrome pdf wkhtml 31
)

_larakit_manage=(
  health report deploy redeploy rollback restart
  logs backup restore ssl-renew queue
  test-mail env webhook update creds
  firewall init db-optimize perf diagnose
  env-check ssh-keys swap crontab php-ext
  db-copy logrotate queue-scale
  cache-clear ssl-info app-create
)

_larakit_top=(
  setup install manage diagnose status update
  apps init list version help
)

_larakit_flags=(--dry-run --quiet --force --help --app --profile -n -q -f -h)

_larakit_presets=(minimal standard postgres full api queue-heavy)

_larakit_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local prev="${COMP_WORDS[COMP_CWORD-1]}"
  local cmd=""

  # Find the main command (first non-flag word after 'larakit')
  local i
  for ((i = 1; i < COMP_CWORD; i++)); do
    local w="${COMP_WORDS[$i]}"
    [[ "$w" == -* ]] && continue
    if [[ -z "$cmd" ]]; then
      cmd="$w"
    fi
  done

  case "$cmd" in
    install|i)
      COMPREPLY=($(compgen -W "${_larakit_modules[*]} --help" -- "$cur"))
      return ;;
    manage|m|run)
      COMPREPLY=($(compgen -W "${_larakit_manage[*]} --help" -- "$cur"))
      return ;;
    setup)
      if [[ "$prev" == "--profile" ]]; then
        COMPREPLY=($(compgen -W "${_larakit_presets[*]}" -- "$cur"))
      elif [[ "$prev" == "--app" ]]; then
        # Complete from existing cred file names
        local apps=()
        for f in "$HOME"/.larakit-creds.*; do
          [[ -f "$f" ]] && apps+=("${f##*\.larakit-creds\.}")
        done
        COMPREPLY=($(compgen -W "${apps[*]}" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "--profile --app --dry-run --quiet --force --help" -- "$cur"))
      fi
      return ;;
    list|ls)
      COMPREPLY=($(compgen -W "modules manage all" -- "$cur"))
      return ;;
    apps|status|update|diagnose|version|help)
      COMPREPLY=($(compgen -W "--help" -- "$cur"))
      return ;;
  esac

  # --app completion — suggest known app names
  if [[ "$prev" == "--app" ]]; then
    local apps=()
    for f in "$HOME"/.larakit-creds.*; do
      [[ -f "$f" ]] && apps+=("${f##*\.larakit-creds\.}")
    done
    COMPREPLY=($(compgen -W "${apps[*]}" -- "$cur"))
    return
  fi

  # --profile completion
  if [[ "$prev" == "--profile" ]]; then
    COMPREPLY=($(compgen -W "${_larakit_presets[*]}" -- "$cur"))
    return
  fi

  # Top-level command
  if [[ "$prev" == "larakit" || -z "$cmd" ]]; then
    COMPREPLY=($(compgen -W "${_larakit_top[*]}" -- "$cur"))
    return
  fi

  # Flags always available
  if [[ "$cur" == -* ]]; then
    COMPREPLY=($(compgen -W "${_larakit_flags[*]}" -- "$cur"))
    return
  fi

  COMPREPLY=()
}

complete -F _larakit_complete larakit
