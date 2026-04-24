# LaraKit — Claude Instructions

> See `AGENTS.md` for the full repository layout, function reference, CLI architecture, and design patterns. This file contains the rules that govern every code change.

---

## What This Project Is

LaraKit is a modular bash-based server installer and management tool for production Laravel stacks. It ships as a `larakit` CLI binary backed by 32 installation modules (00–31) and 32 management scripts. Every script works via the CLI, directly as `bash modules/XX.sh`, or remotely via `curl | bash` from GitHub. All three modes must continue to work after any change.

---

## Non-Negotiable Rules

### Every script must be self-contained
Include the bootstrap header so the script loads its libs from local disk OR from GitHub. Never assume `SETUP_LOADED` is already set. The exact pattern is in AGENTS.md.

### "Detect existing" is mandatory for service modules (05–31)
Check if the service is already installed. Present three choices: reconfigure, reinstall, skip. When `LARAKIT_FORCE=true` (set by `--force`), skip the prompt and reinstall.

### Always offer the last 4 versions
Use `ask_choice` with the four most recent supported versions, newest first. Strip the label after: `VERSION="${VERSION%% *}"`. Current versions (as of 2026):
- PHP: 8.5, 8.4, 8.3, 8.2
- Redis: 8.0, 7.4, 7.2, 7.0
- Node.js: 24, 22, 20, 18

### Save everything to credentials
Every password, port, path, domain, and API key must be saved via `creds_save`. Later modules pre-fill prompts from `creds_load`. No credential should appear only in a prompt.

### Register new items in all required places
- New module → `setup.sh` (3 arrays) + `larakit` (`resolve_module` + `MODULE_META`) + `install.sh` (`MODULES` array) + both completion files
- New manage script → `manage.sh` (2 arrays) + `larakit` (`resolve_manage` + `MANAGE_META`) + `install.sh` (`MANAGE` array) + both completion files
- New top-level CLI command → dispatch `case` in `larakit` + `cmd_help()` + `AGENTS.md` + `CLAUDE.md`
- New setup preset → `run_preset_<name>()` in `setup.sh` + `case` in `setup.sh` main + `select_modules` shortcuts + `cmd_setup_help()` in `larakit` + `completions/larakit.zsh` + docs

---

## Bash Style

| Rule | Detail |
|------|--------|
| Conditions | `[[ ]]` always — never `[ ]` |
| Command substitution | `"$()"` — never backticks |
| Quoting | Always: `"$VAR"`, `"${VAR:-default}"` |
| Arithmetic | `VAR=$((VAR+1))` — not `((VAR++))` (exits with code 1 under `set -e` when result is zero) |
| File editing | `mktemp` + `grep -v` + `mv` — never `sed -i` (macOS-incompatible) |
| Command checks | `has_cmd` — not `which` or inline `command -v` |
| Packages | `pkg_install` — not raw `apt-get install` |
| Idempotent appends | `ensure_line` |
| System file edits | `backup_file` before touching anything |
| System commands | `run_or_dry` — makes all commands dry-run aware |

---

## CLI Flags

Flags are always placed **after** the command. `parse_flags()` strips them from args and exports the env var:

| Flag | Env exported | Effect |
|------|--------------|--------|
| `--dry-run` / `-n` | `DRY_RUN=true` | `run_or_dry` prints instead of executes |
| `--quiet` / `-q` | `LARAKIT_QUIET=true` | All `ask*` prompts return their default silently |
| `--force` / `-f` | `LARAKIT_FORCE=true` | Skip "already installed" detection; force reinstall |
| `--profile <name>` | passed to `setup.sh` | Select a preset: `minimal` `standard` `postgres` `api` `queue-heavy` `full` |
| `--app <name>` | `LARAKIT_APP=<name>` | Target app namespace → `~/.larakit-creds.<name>` |
| `--help` / `-h` | — | Show module/command detail page, then exit |

---

## Bootstrap Pattern

Every module (and manage script) must start with this exact block. The `else` branch is required — without it, modules called from the `larakit` CLI will have no functions because `bash "$path"` spawns a new subprocess that inherits `SETUP_LOADED=1` but not shell functions.

```bash
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
```

Add `_src notify.sh` (and the corresponding `source` in the `else` branch) if the script sends deploy notifications.

---

## Module Checklist

- [ ] Bootstrap header present and unmodified
- [ ] `module_header "Title" "Description"` called first, then `require_root`
- [ ] Pre-fills prompts from `creds_load` where values were previously saved
- [ ] Detect existing service; respects `LARAKIT_FORCE=true`
- [ ] Version selection: `ask_choice` with 4 versions, strips label after
- [ ] All generated values saved via `creds_save` / `creds_section`
- [ ] System commands wrapped in `run_or_dry`
- [ ] `nginx -t` before `systemctl reload nginx`
- [ ] `add_firewall_rule PORT` called for any listening port
- [ ] Registered in `setup.sh` (3 arrays) and `larakit` (resolve + META)
- [ ] Ends with `success "..."` and prints relevant `.env` values

---

## File Naming

| Thing | Convention |
|-------|-----------|
| Installation modules | `NN-kebab-name.sh` (two-digit prefix, in `modules/`) |
| Management scripts | `kebab-name.sh` (in `manage/`) |
| Nginx vhosts | `/etc/nginx/sites-available/<domain>` |
| Octane Nginx vhost | `/etc/nginx/sites-available/<domain>-octane` |
| Supervisor confs | `/etc/supervisor/conf.d/laravel-<service>.conf` |
| Systemd units | `/etc/systemd/system/<service>.service` |

---

## Deploy Notifications

`deploy.sh` and `redeploy.sh` call `notify_deploy` from `lib/notify.sh`. Use the same pattern in any new script that deploys code:

```bash
notify_deploy start   "Deploy started — branch: ${DEPLOY_BRANCH}"
trap 'notify_deploy failure "Deploy FAILED — branch: ${DEPLOY_BRANCH}"' ERR
# ... deploy steps ...
notify_deploy success "Deploy complete — branch: ${DEPLOY_BRANCH}"
```

Post-deploy hooks: check `creds_load DEPLOY_HOOK` and `eval` it if non-empty.

---

## DO NOT

- Remove `set -euo pipefail` from any script
- Remove or alter the bootstrap block
- Use `source <(curl ...)` — always temp-file-and-source
- Use `sed -i` — always `mktemp` + `grep -v` + `mv`
- Use `((VAR++))` under `set -e` — use `VAR=$((VAR+1))`
- Hardcode IP addresses, domains, or passwords anywhere
- Skip `nginx -t` before reloading Nginx
- Skip `require_root` in any module that writes to the system
- Generate credentials without saving them via `creds_save`
- Add a module or manage script without registering it in all required places
- Offer fewer than 4 version choices for versioned software
- Hardcode `~/.larakit-creds` anywhere — always use `creds_load`/`creds_save` which respect `CREDS_FILE`
- Add a new module, manage command, or preset without updating both `completions/larakit.bash` and `completions/larakit.zsh`
