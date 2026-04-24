# LaraKit

[![CI](https://github.com/iamolayemi/larakit/actions/workflows/ci.yml/badge.svg)](https://github.com/iamolayemi/larakit/actions/workflows/ci.yml)

A modular, interactive server installer and management tool for Laravel applications. Covers everything from a fresh Linux server to a fully production-ready Laravel stack — PHP, Nginx, databases, queues, WebSockets, search, monitoring, and zero-downtime deployments.

---

## Install

```bash
sudo bash <(curl -fsSL "https://raw.githubusercontent.com/iamolayemi/larakit/main/install.sh")
```

Or from a local clone:

```bash
git clone https://github.com/iamolayemi/larakit.git && cd larakit
sudo bash install.sh
```

Shell completions (bash and zsh) are installed automatically. To activate in the current session:

```bash
source /etc/bash_completion.d/larakit     # bash
# zsh: completions are placed in /usr/local/share/zsh/site-functions/_larakit
```

To uninstall LaraKit (keeps all your installed software):

```bash
sudo bash <(curl -fsSL "https://raw.githubusercontent.com/iamolayemi/larakit/main/uninstall.sh")
```

---

## Usage

```bash
larakit setup              # full interactive setup wizard (collects credentials automatically)
larakit install <module>   # install a single module
larakit manage <command>   # run a management script
larakit status             # quick service health check
larakit diagnose           # health + firewall + SSL check in one shot
larakit update             # download latest LaraKit scripts from GitHub
larakit apps               # list all configured apps on this server
larakit list               # show all modules and commands
larakit help               # show help
```

`larakit setup` collects all credentials at the start — no need to run `init` separately. Use `larakit init` any time you want to update credentials without reinstalling anything.

### Flags

Place flags **after** the command:

| Flag | Short | Effect |
|------|-------|--------|
| `--dry-run` | `-n` | Print commands without executing anything |
| `--quiet` | `-q` | Accept all prompt defaults — fully non-interactive |
| `--force` | `-f` | Skip "already installed" prompts, force reinstall |
| `--profile <name>` | | Setup preset: `minimal` `standard` `postgres` `full` |
| `--app <name>` | | Target a specific app (uses `~/.larakit-creds.<name>`) |
| `--help` | `-h` | Show help for the command or module |

```bash
larakit setup --profile standard              # skip the menu, use a preset
larakit install mysql --quiet                 # no prompts, use saved defaults
larakit install redis --dry-run               # simulate without changes
larakit install php --force                   # reinstall even if already present
larakit install nginx --help                  # show module detail page
larakit setup --app blog                      # set up a second app on the same server
larakit manage deploy --app blog              # deploy the 'blog' app
```

---

## Installation modules

| # | Module | Versions | What it does |
|---|--------|----------|-------------|
| 00 | Pre-flight | — | OS, disk, RAM, port, and network checks before setup begins |
| 01 | System Init | — | OS updates, swap, timezone, hostname, auto-security updates |
| 02 | Server Hardening | — | Deploy user, SSH hardening, UFW firewall, Fail2ban |
| 03 | PHP | 8.2 / 8.3 / 8.4 / 8.5 | All Laravel extensions + Composer + OPcache |
| 04 | Nginx | Latest stable | Production vhost, gzip, rate limiting, HTTP/2 |
| 05 | MySQL / MariaDB | MySQL 8.0 / 8.4 / 9.2 · MariaDB 10.11 / 11.4 / 11.7 | Creates app DB and user |
| 06 | Redis | 7.0 / 7.2 / 7.4 / 8.0 | Auth, persistence, eviction tuning |
| 07 | Node.js | 18 / 20 / 22 / 24 | NVM install, optional Yarn / pnpm / Bun |
| 08 | SSL / TLS | Let's Encrypt | Certbot, Nginx plugin, auto-renewal timer |
| 09 | Laravel App | — | Clone repo, .env, composer, migrate, cache, permissions |
| 10 | Queue Worker | — | Supervisor + multi-process `queue:work` |
| 11 | Scheduler | — | Cron or Supervisor daemon for `schedule:run` |
| 12 | Horizon | — | Dashboard + Supervisor + Nginx `/horizon` with auth |
| 13 | Reverb | — | WebSocket server + Supervisor + Nginx proxy |
| 14 | Octane | Swoole / FrankenPHP / RoadRunner | Supervisor + Nginx proxy |
| 15 | MinIO | Latest | S3-compatible object storage + Nginx proxy |
| 16 | PostgreSQL | 15 / 16 / 17 | PGDG repo, PGTune config, Laravel extensions |
| 17 | Meilisearch | Latest | Full-text search for Laravel Scout |
| 18 | Typesense | 26.0 / 27.1 | Typo-tolerant search — alternative to Meilisearch |
| 19 | Elasticsearch | 7.17 / 8.12 / 8.13 | + optional Kibana for Scout or custom indexing |
| 20 | RabbitMQ | 3.11 / 3.12 / 3.13 | AMQP message broker — alternative queue driver |
| 21 | Varnish | Latest | HTTP accelerator in front of Nginx |
| 22 | Load Balancer | — | Nginx or HAProxy for horizontal scaling |
| 23 | Mailpit | Latest | SMTP mail catcher + web UI (staging only) |
| 24 | Backups | — | Daily DB dump + file archive + S3/rsync + retention |
| 25 | Tuning | — | sysctl, PHP-FPM pools, Nginx workers, MySQL InnoDB |
| 26 | Monitoring | — | Netdata (metrics) + UptimeKuma (uptime) |
| 27 | phpMyAdmin | Latest stable | Web-based MySQL/MariaDB admin behind Nginx + HTTP auth |
| 28 | pgAdmin 4 | Latest stable | Web-based PostgreSQL admin behind Nginx proxy |
| 29 | Soketi | Latest | Self-hosted Pusher-compatible WebSocket server |
| 30 | Memcached | Latest | In-memory cache — alternative to Redis for pure caching |
| 31 | Headless Chromium | Latest | Chromium + wkhtmltopdf for PDF generation and screenshots |

---

## Management scripts

```bash
larakit manage health          # service statuses, ports, disk, RAM, failed jobs
larakit manage report          # full stack overview — versions, URLs, SSL, queue
larakit manage deploy          # pull latest code + optional composer/cache/restart
larakit manage redeploy        # full deploy with maintenance mode + npm build
larakit manage rollback        # revert to previous release or git commit
larakit manage restart         # restart any combination of services
larakit manage logs            # tail Laravel, Nginx, queue, Horizon, Octane logs
larakit manage backup          # on-demand database backup with optional S3 upload
larakit manage restore         # restore database from .sql.gz backup
larakit manage ssl-renew       # force Let's Encrypt certificate renewal
larakit manage queue           # Supervisor worker status, failed jobs, retry/flush
larakit manage test-mail       # verify SMTP — send test email or check Mailpit inbox
larakit manage env             # build a complete .env from saved credentials
larakit manage webhook         # set up GitHub/GitLab push webhook → auto-deploy
larakit manage update          # download latest LaraKit scripts from GitHub
larakit manage creds           # display or delete stored credentials
larakit manage firewall        # review UFW rules, open ports, surface risks
larakit manage init            # update project credentials without reinstalling
larakit manage db-optimize     # OPTIMIZE TABLE (MySQL) or VACUUM ANALYZE (Postgres)
larakit manage perf            # load test with ab or wrk — req/s and latency
larakit manage env-check       # compare .env against expected keys
larakit manage ssh-keys        # manage authorized_keys for the deploy user
larakit manage swap            # add, resize, or remove swap space
larakit manage crontab         # view and manage application cron entries
larakit manage php-ext         # enable or disable PHP extensions
larakit manage db-copy         # copy database between environments
larakit manage logrotate       # configure log rotation for app and Nginx logs
larakit manage queue-scale     # adjust Supervisor worker count live
larakit manage cache-clear     # flush config, route, view, OPcache, Redis
larakit manage ssl-info        # certificate expiry and chain for all domains
larakit manage app-create      # scaffold a new app — vhost, DB, directory, .env
larakit diagnose               # health + firewall + SSL check in one shot
```

---

## Presets

Skip the module selection menu by passing a preset to `larakit setup`:

| Preset | Includes |
|--------|---------|
| `minimal` | Init, hardening, PHP, Nginx, MySQL, SSL, app |
| `standard` | Minimal + Redis, Node.js, queue worker, scheduler, tuning |
| `postgres` | Standard stack with PostgreSQL instead of MySQL |
| `api` | Headless API stack — no Node.js frontend tooling |
| `queue-heavy` | Standard + Horizon, extra Redis and worker tuning |
| `full` | Every module |

```bash
larakit setup --profile standard
larakit setup --profile postgres --quiet
```

---

## Multiple apps on the same server

LaraKit fully supports running multiple Laravel applications on a single server. Each app gets its own credential namespace, Nginx vhost, database, and deploy user.

```bash
# First app — default
larakit setup

# Second app — named namespace
larakit setup --app blog

# Run any command scoped to a specific app
larakit install mysql --app blog
larakit manage deploy --app blog
larakit manage env-check --app blog

# See all apps configured on this server
larakit apps
```

The `--app <name>` flag routes all credential reads/writes to `~/.larakit-creds.<name>`. Each app's modules prompt for their own domain, database, paths, and Redis config. Infrastructure (PHP, Nginx binary, Redis) is shared; the app layer is isolated.

**Auto-detection:** If you're inside an app directory, LaraKit detects which app you mean automatically — no flag needed:

```bash
cd /var/www/blog
larakit manage deploy          # auto-detects: app=blog
larakit manage env-check       # reads ~/.larakit-creds.blog automatically
larakit status                 # shows health for the blog app context
```

LaraKit scans all `~/.larakit-creds.*` files for `APP_PATH` entries matching your current directory (longest match wins). Explicit `--app` always takes precedence over auto-detection.

**Pinning with a `.larakit` file** — place a `.larakit` file in your project root for reliable detection without path matching:

```bash
echo "APP=blog" > /var/www/blog/.larakit
```

LaraKit walks up from `$PWD` looking for this file, so it works from any subdirectory of the project. `.larakit` takes priority over path-based detection.

---

## Credentials

`larakit setup` collects all credentials at the start before installing anything. Every module then pre-fills its prompts from `~/.larakit-creds`. Use `larakit init` any time you want to update credentials without reinstalling.

```bash
larakit init               # update credentials only
larakit manage creds       # view saved credentials
rm ~/.larakit-creds        # delete after saving everything securely
```

---

## Deploy notifications

`deploy` and `redeploy` fire webhooks automatically when a key is saved to `~/.larakit-creds`:

```
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
TELEGRAM_BOT_TOKEN=123456:ABC-...
TELEGRAM_CHAT_ID=-1001234567890
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
DEPLOY_HOOK=php /var/www/app/artisan horizon:terminate   # post-deploy shell command
```

Notifications fire on start, success, and failure (via `trap ERR`).

---

## Local testing with Docker

Test on a real Ubuntu 24.04 environment without a cloud server:

```bash
# Enter the container — repo is mounted live
docker compose -f docker/docker-compose.yml run larakit

# Inside the container (you are root)
larakit setup --profile standard --dry-run
larakit install php --quiet
larakit install mysql
```

Edits on your host machine appear inside the container immediately.

---

## Project structure

```
.
├── larakit              # CLI binary → /usr/local/bin after install
├── install.sh           # Installs CLI + bash completion to /opt/larakit
├── config.sh            # GitHub user/repo defaults
├── setup.sh             # Orchestrator (interactive or --profile)
├── manage.sh            # Management console
├── lib/
│   ├── colors.sh        # Terminal colours, banner
│   ├── prompts.sh       # ask, ask_yn, ask_choice (quiet-mode aware)
│   ├── creds.sh         # Credential save/load/display
│   ├── utils.sh         # Shared utilities
│   └── notify.sh        # Slack / Telegram / Discord notifications
├── modules/             # 32 installation modules (00–31)
├── manage/              # 32 management scripts
├── tests/               # syntax-check, test-libs, test-cli
└── docker/              # Ubuntu 24.04 image for local testing
```

---

## Adding a new module

1. Copy any existing module — the bootstrap block at the top handles local and remote execution
2. `module_header "Title" "Description"` + `require_root` at the top
3. Pre-fill prompts with `creds_load KEY`; save outputs with `creds_save KEY VALUE`
4. Wrap system commands in `run_or_dry` for dry-run support
5. Register in `setup.sh` (`MODULE_FILES`, `MODULE_NAMES`, `MODULE_CATEGORIES`) and in `larakit` (`resolve_module` case + `MODULE_META` entry)

### Bootstrap block

```bash
if [[ -z "${SETUP_LOADED:-}" ]]; then
  _D="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  _BASE="$(dirname "$_D")"
  [[ -f "${_BASE}/config.sh" ]] && source "${_BASE}/config.sh"
  _src() {
    local f="$1"
    if [[ -f "${_BASE}/lib/${f}" ]]; then source "${_BASE}/lib/${f}"
    else local t; t=$(mktemp); curl -fsSL "${SETUP_BASE_URL}/lib/${f}" -o "$t" && source "$t"; rm -f "$t"; fi
  }
  _src colors.sh; _src prompts.sh; _src creds.sh; _src utils.sh
  export SETUP_LOADED=1
fi
```

---

## Supported systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12

**Requires bash 4+** (standard on all supported distros).

---

## Contributing

PRs welcome. Test on a fresh Ubuntu 24.04 server or via `docker compose -f docker/docker-compose.yml run larakit`.
