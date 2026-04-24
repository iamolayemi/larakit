# LaraKit — Agent Instructions

## Project Purpose

LaraKit is a modular, interactive bash installer and management tool for production Laravel servers.
It ships as a `larakit` CLI binary backed by standalone modules. Every module works both via the
CLI and as a direct `curl | bash` invocation from GitHub — no server installation required.

---

## Repository Layout

```
larakit/
├── larakit                # CLI binary (installed to /usr/local/bin)
├── install.sh         # Installs CLI + bash completion to /opt/larakit/
├── setup.sh               # Interactive orchestrator (runs all or selected modules)
├── manage.sh              # Interactive management console
├── config.sh              # GitHub user/repo/branch defaults
├── lib/
│   ├── colors.sh          # Terminal colors, banner, formatting helpers
│   ├── prompts.sh         # Interactive prompt helpers (quiet-mode aware)
│   ├── creds.sh           # Credential save/load/display → ~/.larakit-creds
│   ├── utils.sh           # Shared utilities (require_root, run_quiet, spinner, etc.)
│   └── notify.sh          # Slack / Telegram / Discord deploy notifications
├── modules/
│   ├── 00-preflight.sh        # OS, disk, RAM, port, and network pre-checks
│   ├── 01-system-init.sh      # OS updates, swap, timezone, hostname
│   ├── 02-server-hardening.sh # Deploy user, SSH hardening, UFW, Fail2ban
│   ├── 03-php.sh              # PHP 8.2/8.3/8.4 + extensions + Composer + OPcache
│   ├── 04-nginx.sh            # Nginx + Laravel vhost + gzip + rate limiting
│   ├── 05-mysql.sh            # MySQL 8.0/8.4/9.2 or MariaDB 10.11/11.4/11.7
│   ├── 06-redis.sh            # Redis 7.0/7.2/7.4 with auth + persistence + tuning
│   ├── 07-node.sh             # Node.js 18/20/22 via NVM + optional Yarn/pnpm/Bun
│   ├── 08-ssl.sh              # Let's Encrypt via Certbot (Nginx/standalone/DNS)
│   ├── 09-laravel-app.sh      # Clone repo, .env, composer, migrate, cache, permissions
│   ├── 10-queue-worker.sh     # Supervisor + queue:work with multi-process config
│   ├── 11-scheduler.sh        # Cron or Supervisor daemon for schedule:run
│   ├── 12-horizon.sh          # Horizon + Supervisor + Nginx basic auth
│   ├── 13-reverb.sh           # Reverb WebSocket + Supervisor + Nginx proxy
│   ├── 14-octane.sh           # Octane (Swoole/FrankenPHP/RoadRunner) + Nginx proxy
│   ├── 15-minio.sh            # MinIO S3-compatible storage + Nginx proxy
│   ├── 16-postgres.sh         # PostgreSQL 15/16/17 with PGTune-style config
│   ├── 17-meilisearch.sh      # Meilisearch search engine for Laravel Scout
│   ├── 18-typesense.sh        # Typesense search engine for Laravel Scout
│   ├── 19-elasticsearch.sh    # Elasticsearch 7/8 + optional Kibana
│   ├── 20-rabbitmq.sh         # RabbitMQ AMQP message broker
│   ├── 21-varnish.sh          # Varnish HTTP accelerator in front of Nginx
│   ├── 22-load-balancer.sh    # Nginx or HAProxy for horizontal scaling
│   ├── 23-mailpit.sh          # SMTP mail catcher + web UI (staging only)
│   ├── 24-backups.sh          # DB dump + file backup + S3/rsync + cron
│   ├── 25-tuning.sh           # sysctl, PHP-FPM pools, Nginx workers, MySQL InnoDB
│   ├── 26-monitoring.sh       # Netdata real-time metrics + UptimeKuma uptime
│   ├── 27-phpmyadmin.sh       # phpMyAdmin behind Nginx + HTTP Basic Auth
│   ├── 28-pgadmin.sh          # pgAdmin 4 behind Nginx proxy
│   ├── 29-soketi.sh           # Soketi Pusher-compatible WebSocket server
│   ├── 30-memcached.sh        # Memcached in-memory cache
│   └── 31-chromium.sh         # Headless Chromium + wkhtmltopdf for PDF/screenshots
├── manage/
│   ├── health.sh              # Service status, ports, disk, RAM, failed jobs
│   ├── report.sh              # Full stack overview with versions, URLs, SSL
│   ├── deploy.sh              # Pull code + optional composer/cache/restart
│   ├── redeploy.sh            # Full deploy with maintenance mode + npm build
│   ├── rollback.sh            # Roll back to previous Deployer release or git commit
│   ├── restart.sh             # Restart PHP-FPM, Nginx, workers, Horizon, Octane
│   ├── logs.sh                # Tail Laravel, Nginx, queue, Horizon, Octane logs
│   ├── db-backup.sh           # On-demand database backup with optional S3 upload
│   ├── db-restore.sh          # Restore database from .sql.gz backup
│   ├── ssl-renew.sh           # Force Let's Encrypt certificate renewal
│   ├── queue-status.sh        # Supervisor workers, failed jobs, retry/flush
│   ├── test-mail.sh           # Verify SMTP — artisan, raw nc, or Mailpit inbox
│   ├── generate-env.sh        # Build complete .env from saved credentials
│   ├── webhook-listen.sh      # GitHub/GitLab push webhook → auto-deploy
│   ├── self-update.sh         # Download latest scripts from GitHub
│   ├── credentials.sh         # Display or delete stored credentials
│   ├── firewall-audit.sh      # Review UFW rules, open ports, surface risks
│   ├── init.sh                # Update credentials without reinstalling
│   ├── db-optimize.sh         # OPTIMIZE TABLE / VACUUM ANALYZE + size report
│   ├── performance-test.sh    # ab/wrk load test → req/s + latency
│   ├── diagnose.sh            # health + firewall-audit + SSL check in one shot
│   ├── env-check.sh           # Compare .env against expected Laravel keys
│   ├── ssh-keys.sh            # View/add/remove authorized_keys for deploy user
│   ├── swap.sh                # Add, resize, or remove swap space
│   ├── crontab.sh             # View and manage application cron entries
│   ├── php-ext.sh             # Enable or disable PHP extensions interactively
│   ├── db-copy.sh             # Copy database between environments (prod→staging)
│   ├── logrotate.sh           # Configure logrotate for Laravel, Nginx, Supervisor
│   ├── queue-scale.sh         # Adjust Supervisor numprocs live
│   ├── cache-clear.sh         # Flush config, route, view, OPcache, and Redis cache
│   ├── ssl-info.sh            # SSL certificate expiry and chain for all domains
│   └── app-create.sh          # Scaffold a new app — directory, vhost, DB, .env
├── completions/
│   ├── larakit.bash           # Bash tab-completion (installed to /etc/bash_completion.d/)
│   └── larakit.zsh            # Zsh tab-completion (installed to zsh site-functions/)
├── tests/
│   ├── syntax-check.sh        # bash -n on every .sh file + larakit binary
│   ├── test-libs.sh           # 15 unit assertions for lib functions
│   └── test-cli.sh            # CLI smoke tests (version, help, --help flags, error exits)
├── docker/
│   ├── Dockerfile             # Ubuntu 24.04 image for local testing
│   └── docker-compose.yml     # Mounts repo live, privileged for systemctl
├── uninstall.sh               # Removes LaraKit CLI + scripts; never touches installed software
└── .github/workflows/ci.yml   # CI: syntax → shellcheck → shfmt → unit tests → compat matrix
```

---

## CLI Architecture

The `larakit` binary is the main user entrypoint. It:

1. Sources all four libs from `$LARAKIT_HOME/lib/`
2. Resolves friendly names/numbers to filenames via `resolve_module()` / `resolve_manage()`
3. Parses flags from remaining args with `parse_flags()` — flags always come **after** the command
4. Dispatches to `setup.sh`, a module, or a manage script

### Command structure

```
larakit <command> [args] [flags]

Commands:
  setup                  Interactive full setup wizard (credential wizard runs first)
  install <module>       Run a single installation module
  manage <command>       Run a management script
  diagnose               Health + firewall + SSL check in one shot
  status                 Quick service health check (alias: manage health)
  update                 Download latest LaraKit scripts (alias: manage update)
  apps                   List all configured apps on this server
  init                   Update credentials without reinstalling
  list [modules|manage]  List available modules/commands
  version                Show version
  help                   Show help

Flags (placed after command):
  --dry-run / -n         Simulate without making changes (sets DRY_RUN=true)
  --quiet / -q           Use defaults for all prompts (sets LARAKIT_QUIET=true)
  --force / -f           Skip "already installed" prompts (sets LARAKIT_FORCE=true)
  --profile <name>       Setup preset: minimal, standard, postgres, full, api, queue-heavy
  --app <name>           Target app namespace → uses ~/.larakit-creds.<name>
  --help / -h            Show help for the command or module
```

### Module name aliases

Modules support numbers and multiple name aliases:

```
larakit install php        # or: larakit install 3 / larakit install 03
larakit install mysql      # or: mariadb / db / 5 / 05
larakit manage firewall    # or: firewall-audit / fwaudit
```

### Adding new items to the CLI

When adding a new module `NN-name.sh`:
1. Add a case entry in `resolve_module()` in `larakit`
2. Add an entry in `MODULE_META` associative array
3. Register in `setup.sh`: `MODULE_FILES[]`, `MODULE_NAMES[]`, `MODULE_CATEGORIES[]`

When adding a new manage script `name.sh`:
1. Add a case entry in `resolve_manage()` in `larakit`
2. Add an entry in `MANAGE_META` associative array
3. Register in `manage.sh`: `MANAGE_FILES[]`, `MANAGE_NAMES[]`

When adding a new top-level CLI command:
1. Add a dispatch `case` entry in the main `case "$CMD"` block in `larakit`
2. Add to `cmd_help()` commands list
3. Document here in `AGENTS.md` and in `CLAUDE.md`

### Multi-app support

LaraKit supports multiple apps on the same server using the `--app <name>` flag.

```bash
larakit setup --app blog           # credentials → ~/.larakit-creds.blog
larakit manage deploy --app blog   # deploys the 'blog' app
larakit apps                       # list all configured apps
```

**How it works:**
- `parse_flags()` exports `LARAKIT_APP` when `--app` is present
- After `parse_flags`, `resolve_creds_file()` calls `auto_detect_app()` if `LARAKIT_APP` is still unset
- `auto_detect_app()` scans all `~/.larakit-creds.*` files for `APP_PATH` values matching `$PWD` — longest match wins
- `CREDS_FILE` is then re-pointed to `~/.larakit-creds.<name>` and forwarded to modules via `run_module()`/`run_manage()`
- All credential reads/writes are automatically scoped to the named file
- Infrastructure (PHP, Nginx, Redis binary) is shared; Nginx vhosts and databases are per-domain

**Auto-detection priority:** `--app <name>` flag → `.larakit` project file (walk up) → `$PWD` path match → default `~/.larakit-creds`

**`.larakit` project file** — pin an app name per-repo so detection works from any subdirectory:

```bash
echo "APP=blog" > /var/www/blog/.larakit
```

`auto_detect_app()` walks up from `$PWD` to `/` looking for `.larakit`, reads `APP=`, and sets `LARAKIT_APP`. This takes priority over path-based detection.

### Version update check

`larakit version` queries the GitHub Releases API (3s timeout, non-blocking) and prints an upgrade notice when a newer tag exists. Reads `GITHUB_USER` / `GITHUB_REPO` from `config.sh`.

**Rules for module authors:**
- Never hardcode `~/.larakit-creds` — always use `creds_load`/`creds_save` which respect `CREDS_FILE`
- Domain, path, and DB name are read from creds — they will differ per app automatically

---

## Core Design Patterns

### Bootstrap header (every module and manage script)

Every script is self-contained — it loads libs from local disk if available, otherwise downloads
from GitHub. This pattern must be preserved exactly:

```bash
if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh"
  _src() {
    local f="$1"
    if [[ -f "${_BASE}/lib/${f}" ]]; then
      source "${_BASE}/lib/${f}"
    else
      local t; t=$(mktemp)
      curl -fsSL "${SETUP_BASE_URL}/lib/${f}" -o "$t" && source "$t"
      rm -f "$t"
    fi
  }
  _src colors.sh; _src prompts.sh; _src creds.sh; _src utils.sh
  export SETUP_LOADED=1
fi
```

Manage scripts set `_BASE="$(dirname "$_D")"` (one level up from `manage/`).
Modules set `_BASE` one level up from `modules/`.

### "Detect existing" pattern

Modules that install services MUST check if the service is already running and offer three choices:

```bash
if has_cmd <binary>; then
  warn "<Service> is already installed."
  ask_choice choice "What would you like to do?" \
    "Reconfigure (keep binary, update settings)" \
    "Reinstall (download fresh)" \
    "Skip"
  [[ "$choice" == "Skip" ]] && { info "Skipping."; exit 0; }
  [[ "$choice" == "Reconfigure"* ]] && SKIP_INSTALL=true
fi
```

When `LARAKIT_FORCE=true` is set (via `--force` flag), skip the prompt and default to reinstall.

### Version selection convention

Always offer the last **4** supported versions, newest first, with a label. Strip the label after:

```bash
ask_choice PHP_VERSION "Select PHP version:" \
  "8.5 (Latest — 2026)" \
  "8.4 (Stable — recommended)" \
  "8.3 (Stable)" \
  "8.2 (Security fixes only)"
PHP_VERSION="${PHP_VERSION%% *}"   # → "8.5"
```

Current version lists (as of 2026):
- **PHP**: 8.5, 8.4, 8.3, 8.2
- **Redis**: 8.0, 7.4, 7.2, 7.0
- **Node.js**: 24, 22, 20, 18
- **MySQL**: 9.2, 8.4, 8.0 / **MariaDB**: 11.7, 11.4, 10.11
- **PostgreSQL**: 17, 16, 15

### Credential persistence

All passwords, ports, paths, API keys, and domain names must be saved so later modules can
pre-fill their prompts without asking the user again:

```bash
creds_section "Redis"
creds_save REDIS_PASSWORD "$REDIS_PASSWORD"
creds_save REDIS_PORT     "$REDIS_PORT"
```

Pre-fill from saved values at the top of the module:

```bash
REDIS_PORT="$(creds_load REDIS_PORT 2>/dev/null || echo "6379")"
ask REDIS_PORT "Redis port" "$REDIS_PORT"
```

### Quiet mode

When `LARAKIT_QUIET=true` all `ask*` functions in `prompts.sh` immediately return the default
value without prompting. This is set by the `--quiet` / `-q` flag via `parse_flags()`.

### Dry-run mode

When `DRY_RUN=true` all `run_or_dry()` calls print the command instead of executing it.
Set by the `--dry-run` / `-n` flag. Test: `DRY_RUN=true bash modules/05-mysql.sh`.

### Nginx config files

- Standard vhost: `/etc/nginx/sites-available/<domain>`
- Octane proxy: `/etc/nginx/sites-available/<domain>-octane`
- Always run `nginx -t && systemctl reload nginx` after writing config

### Systemd services

- Always use `service_enable_start <name>` from utils.sh — this enables AND restarts (survives reboot)
- Systemd unit files go in `/etc/systemd/system/<service>.service`
- After writing a unit: `systemctl daemon-reload` before `service_enable_start`

### Supervisor configs

- Config dir: `/etc/supervisor/conf.d/laravel-<service>.conf`
- After writing: `supervisorctl reread && supervisorctl update`

### Deploy notifications

`lib/notify.sh` provides `notify_deploy <event> <message>` which fires Slack, Telegram, and
Discord webhooks if configured. `deploy.sh` and `redeploy.sh` call it at start, on completion,
and via `trap ERR` on failure. Save `SLACK_WEBHOOK_URL`, `TELEGRAM_BOT_TOKEN`+`TELEGRAM_CHAT_ID`,
or `DISCORD_WEBHOOK_URL` to credentials to activate.

Post-deploy hooks: `creds_load DEPLOY_HOOK` returns a shell command or script path run after
deploy. Both `deploy.sh` and `redeploy.sh` read and eval this value if set.

---

## Key Library Functions

| Function | File | Purpose |
|---|---|---|
| `ask VAR "Q" [default]` | prompts.sh | Text prompt (respects `LARAKIT_QUIET`) |
| `ask_secret VAR "Q"` | prompts.sh | Hidden password prompt |
| `ask_yn VAR "Q" [y\|n]` | prompts.sh | Yes/No prompt |
| `ask_choice VAR "Q" opt1...` | prompts.sh | Numbered single-select |
| `ask_multiselect VAR "Q" opt1...` | prompts.sh | Multi-select by number or "all" |
| `confirm_or_exit "Q"` | prompts.sh | Ask y/n, exit 0 on no |
| `creds_save KEY VALUE` | creds.sh | Persist a credential |
| `creds_load KEY` | creds.sh | Load a saved credential |
| `creds_section LABEL` | creds.sh | Section comment in creds file |
| `creds_show` | creds.sh | Pretty-print all credentials |
| `gen_password [len]` | creds.sh | Random password with symbols |
| `gen_secret [len]` | creds.sh | Random alphanumeric secret |
| `require_root` | utils.sh | Exit if not running as root |
| `has_cmd CMD` | utils.sh | Check if command exists |
| `pkg_install pkg...` | utils.sh | DEBIAN_FRONTEND=noninteractive apt-get install |
| `service_enable_start NAME` | utils.sh | systemctl enable + restart |
| `service_running NAME` | utils.sh | systemctl is-active check |
| `backup_file FILE` | utils.sh | Timestamped `.bak` copy |
| `ensure_line LINE FILE` | utils.sh | Idempotent line append |
| `set_env_value KEY VAL FILE` | utils.sh | Replace or insert KEY=VAL in file |
| `add_firewall_rule PORT [proto]` | utils.sh | ufw allow rule |
| `module_header TITLE DESC` | utils.sh | Module section banner |
| `run_quiet "msg" cmd...` | utils.sh | Run with spinner; show error log on fail |
| `run_or_dry cmd...` | utils.sh | Execute or print (dry-run aware) |
| `spinner PID "msg"` | utils.sh | Braille spinner while PID runs |
| `get_public_ip` | utils.sh | curl ipify / icanhazip / hostname -I |
| `notify_deploy event "msg"` | notify.sh | Fire Slack/Telegram/Discord webhook |
| `notify_configure` | notify.sh | Interactively set webhook URLs |

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `SETUP_BASE_URL` | GitHub raw URL | Base URL for remote lib/module downloads |
| `SETUP_BASE_DIR` | Script directory | Local base directory |
| `SETUP_LOADED` | (unset) | Set to `1` — prevents double-loading libs |
| `LARAKIT_HOME` | `/opt/larakit` | CLI installation directory |
| `CREDS_FILE` | `~/.larakit-creds` | Credential storage path |
| `DRY_RUN` | `false` | Print commands instead of running |
| `LARAKIT_QUIET` | `false` | Accept all prompt defaults silently |
| `LARAKIT_FORCE` | `false` | Skip "already installed" detection |
| `GITHUB_USER` | `iamolayemi` | GitHub username for remote URLs |
| `GITHUB_REPO` | `larakit` | GitHub repo name |

---

## How to Add a New Module

1. Copy the bootstrap header from any existing module
2. Call `module_header "Title" "Description"` and `require_root`
3. Load saved values via `creds_load` to pre-fill prompts
4. Use `ask_choice` for version selection (last 4 versions, newest first)
5. Implement "detect existing" with three choices (reconfigure / reinstall / skip)
6. Respect `LARAKIT_FORCE=true` — skip the detect-existing prompt and reinstall
7. Use `run_or_dry` for all commands that write to the system
8. Save credentials via `creds_save` / `creds_section`
9. End with `success "Module complete."` and any usage hints (env vars, commands)
10. Register in all four places:
    - `setup.sh`: `MODULE_FILES[]`, `MODULE_NAMES[]`, `MODULE_CATEGORIES[]`
    - `larakit`: `resolve_module()` case + `MODULE_META[]` entry

---

## How to Add a New Management Script

1. Copy the bootstrap header from any existing manage script (note `_BASE` is one level up)
2. Source `notify.sh` in the `_src` chain if the script deploys code
3. Save any new credentials the script generates
4. Register in two places:
   - `manage.sh`: `MANAGE_FILES[]`, `MANAGE_NAMES[]`
   - `larakit`: `resolve_manage()` case + `MANAGE_META[]` entry

---

## Testing Locally with Docker

The `docker/` directory provides a real Ubuntu 24.04 environment for testing without a cloud server:

---

## Setup Presets

Presets are defined in `setup.sh` as `run_preset_<name>()` functions. Each sets `SELECTED_MODULES[]`.

| Preset | Modules included |
|--------|-----------------|
| `minimal` | system-init, hardening, php, nginx, mysql, ssl, app |
| `standard` | Minimal + redis, node, queue, scheduler, tuning |
| `postgres` | Standard with postgres instead of mysql |
| `api` | Headless API — like standard but no node/frontend tooling |
| `queue-heavy` | Standard + horizon, extra Redis/tuning |
| `full` | Every module |

To add a new preset: add `run_preset_<name>()` to `setup.sh`, add the name to the `case` block in `setup.sh`'s `main()`, and update the `--profile` descriptions in `larakit`'s `cmd_setup_help()` and here.

---

## Shell Completions

`completions/larakit.bash` — sourced by bash, installed to `/etc/bash_completion.d/larakit` by `install.sh`.  
`completions/larakit.zsh` — `#compdef` style, installed to `/usr/local/share/zsh/site-functions/_larakit`.

Both complete: top-level commands, module names, manage command names, `--profile` values, and `--app` values (dynamically from existing `~/.larakit-creds.*` files).

**Keep completions in sync** when adding new modules or manage commands — update both files.

---

```bash
# Build and enter the container
docker compose -f docker/docker-compose.yml run larakit

# Inside the container — you're root on a fresh Ubuntu server
bash setup.sh                    # full wizard
bash modules/03-php.sh           # single module
DRY_RUN=true bash setup.sh       # dry run
LARAKIT_QUIET=true bash modules/05-mysql.sh  # non-interactive
```

The repo is mounted live at `/larakit` — edits on your machine appear immediately without rebuilding.

---

## CI Pipeline

`.github/workflows/ci.yml` runs on every push and PR:

| Job | What it checks |
|-----|----------------|
| `syntax` | `bash -n` on all `.sh` files + `larakit` binary |
| `test-libs` | 15 unit assertions (colors, creds, utils functions) |
| `shellcheck` | ShellCheck linting (SC1090/91/2034/2154 disabled via `.shellcheckrc`) |
| `shfmt` | Formatting check |
| `validate-cli` | Runs `tests/test-cli.sh` — version, help, list, all `--help` flags, error exits |
| `compat` | Matrix: Ubuntu 22.04 / 24.04 |

`syntax` must pass before any other job runs.

---

## Conventions

- All scripts use `set -euo pipefail`
- Arithmetic: `VAR=$((VAR+1))` not `((VAR++))` — avoids `set -e` exit when result is zero
- Use `pkg_install` (not raw `apt-get`) for packages
- Never hardcode passwords — always `gen_password` or prompt
- Always `backup_file` before modifying system config files
- File edits: use `mktemp` + `grep -v` + `mv` pattern (not `sed -i` — macOS incompatible)
- Prefer `[[ ]]` over `[ ]` for conditions
- Quote all variable expansions: `"$VAR"`, `"${VAR:-default}"`
- Use `has_cmd` (not `which`) to test for commands
- Use `ensure_line` for idempotent config file lines
