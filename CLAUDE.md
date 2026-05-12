# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Confiraspa V2** is a fully bash-based provisioning framework for Raspberry Pi OS (Bookworm/Bullseye). It automates setting up a home production server (NAS, media server, torrent client, cloud backups, etc.) with a focus on idempotency, security, and structured logging. The system runs with root privileges on production hardware; mistakes can leave the server inoperable or expose sensitive data.

Key areas: filesystem mounts (`fstab`), service credentials (`.env`), firewall rules (UFW), and scheduled jobs (cron). All of these are production-critical.

## Role and Non-Negotiable Principles

Act as a senior engineer responsible for quality, resilience, and security. Never sacrifice these for speed or brevity.

1. **Idempotency first.** Every script must be safe to run multiple times. Check existing state before acting; never assume a clean slate.
2. **Use `execute_cmd` for all system-mutating calls.** This is mandatory — it enables dry-run support and consistent logging.
3. **Never silence errors.** `set -euo pipefail` and ERR traps are non-negotiable. Do not add `|| true` to mask failures unless explicitly justified with a comment.
4. **Back up before overwriting.** Use `create_backup` before modifying any config file that already exists.
5. **Log through `lib/utils.sh`.** Never use bare `echo` for status messages. Use `log_info`, `log_success`, `log_error`, etc.
6. **No new dependencies without justification.** Bash, `jq`, `curl`, `systemctl`, and standard coreutils are available. Adding anything else requires an explicit reason.
7. **Validate variables before use.** Use `validate_var` from `lib/validators.sh` for any variable sourced from `.env` before it is used in a destructive or path-sensitive context. Because `set -u` is active globally, always use default-value syntax `${VAR:-}` when testing variables that might be absent from `.env` — bare `$VAR` inside an `if` or `[[ ]]` will abort the script if the variable is unset.
8. **Propose design first for architectural changes.** If a change touches `install.sh`, `lib/`, or the stage execution model, describe the impact and risks before writing code.

## Running the Provisioner

```bash
# First run: install dependencies, make scripts executable, create .env
sudo ./bootstrap.sh

# Full provisioning
sudo ./install.sh

# Simulate without making changes
sudo ./install.sh --dry-run

# Run a single script (match by basename or full path)
sudo ./install.sh --only samba
sudo ./install.sh --only scripts/30-services/samba.sh
```

There is no build suite or linter. All scripts are pure bash. Validate logic manually with `--dry-run` and by reading the output carefully.

## Architecture

### Entry Points

- **`bootstrap.sh`** — One-time setup: installs `git`, `jq`, `curl`, makes scripts executable, creates `.env` from `.env.example`.
- **`install.sh`** — Main orchestrator. Loads `.env`, iterates through the `STAGES` array, runs each script in a subprocess. Supports `--dry-run` and `--only` filters. Creates a timestamped log in `logs/`.

### Shared Libraries (`lib/`)

Read these before modifying any logging or command execution behavior. They are the foundation all scripts depend on.

- **`lib/utils.sh`** — Core utilities: logging (`log_info`, `log_success`, `log_error`, etc.), `execute_cmd` (dry-run-aware command runner), `ensure_package` (lazy APT), `download_secure` (retry + SHA256), `wait_for_service` (port polling via `/dev/tcp/`), `create_backup`, `check_disk_space`.
- **`lib/validators.sh`** — `validate_root`, `require_system_commands`, `require_service_commands` (skipped in dry-run), `validate_var`.
- **`lib/colors.sh`** — ANSI color constants used by the logging system.

### Scripts (`scripts/`)

Organized by provisioning stage and executed in order:

| Stage | Directory | Purpose |
|-------|-----------|---------|
| 00 | `00-system/` | OS updates, users/groups, disk mounts & fstab |
| 10 | `10-network/` | UFW firewall, optional XRDP/VNC |
| 30 | `30-services/` | Samba, Arr suite, Transmission, Plex, rclone, rsync, Calibre, aMule, Webmin |
| 40 | `40-maintenance/` | Cron jobs, cloud/local backups, cleanup, log rotation, permission sync |

### Configuration

- **`.env`** — Runtime secrets and paths (gitignored). Copy from `.env.example` and fill in values before running.
- **`configs/static/`** — JSON-driven configuration for mounts, cron jobs, cloud backups, retention policies, and restore mappings.
- **`configs/static/templates/`** — Config file templates with `${VAR}` placeholders substituted via `envsubst` at provisioning time (smb.conf, transmission.json, etc.).

## Key Patterns

### Dry-Run Support

Every script receives `--dry-run` from `install.sh`. The `execute_cmd` wrapper echoes commands with `[DRY-RUN]` instead of running them. Use `execute_cmd` for all system-mutating calls — no exceptions.

The signature is strictly: `execute_cmd "command string" "Optional log message"`. Because the function evaluates the command via `bash -c "$cmd"`, the entire command must be passed as a single quoted string. Pay extreme attention to escaping inner quotes — for example: `execute_cmd "sed -i 's/old/new/' /etc/file" "Updating config"`. Broken quoting causes silent misbehavior that only appears at runtime, not in dry-run.

### Idempotency

Scripts check existing state before acting: `dpkg -l` before installing packages, file diffs before overwriting configs, `systemctl is-active` before restarting services.

When checking system state that may not yet exist during a `--dry-run` (e.g., a user or group created in an earlier simulated step, or a directory that would have been made), guard the check so it does not abort the script. Use the pattern `if [[ "${DRY_RUN:-false}" != true ]]; then assert_or_check ...; fi` or explicitly handle the missing state with a `log_info` warning and a graceful `return 0`.

### Error Handling

Scripts use `set -euo pipefail` and a trap on `ERR` that calls the error handler with `${BASH_LINENO[0]}`. Critical file writes back up originals via `create_backup` and restore on failure.

### JSON-Driven Operations

Maintenance scripts (`backup_cloud.sh`, `cleanup_backups.sh`, `restore_apps.sh`) iterate over JSON arrays using `jq`. Follow the same pattern when adding new jobs.

**Never pipe into `while read` loops.** Piping (`jq ... | while read`) creates a subshell where variable assignments are lost and `set -e` does not propagate correctly. Always use process substitution instead:

```bash
# WRONG — variables set inside the loop are lost; errors may be swallowed
jq -r '.[]' file.json | while read -r item; do
    result="$item"  # lost after the loop
done

# CORRECT — loop runs in the current shell; set -euo pipefail applies
while read -r item; do
    result="$item"
done < <(jq -r '.[]' file.json)
```

### Cron Management (`40-maintenance/cron.sh`)

Uses `BEGIN CONFIRASPA`/`END CONFIRASPA` markers in the system crontab to isolate managed tasks. Replaces only the Confiraspa block, leaving user-added entries intact.

### Logging

All output goes through `lib/utils.sh` log functions. These write colored output to stderr and plain text to the current run's log file in `logs/`. Never use bare `echo` for status messages.

## Security Rules

The system handles credentials (cloud storage tokens, Samba passwords, service API keys) and runs as root. Apply these rules without exception:

- **Never log sensitive values.** Credentials, tokens, and passwords from `.env` must never appear in log output or be echoed to stdout. Log variable names, not values.
- **Never hardcode secrets.** All secrets must come from `.env` and be validated with `validate_var` before use.
- **Validate all external input.** Any value read from a file, URL, or user-supplied argument must be validated (type, range, allowlist) before being used in a command.
- **Use `download_secure` for all remote downloads.** It enforces SHA256 verification and retries. Never use bare `curl | bash`.
- **Firewall rules are additive, not destructive.** When modifying UFW rules, add or update specific rules; never flush all rules unless that is the explicit intent with a clear justification in the code.
- **Avoid world-writable permissions.** Never set `chmod 777`. Prefer the minimum permissions needed.
- **Mark security-relevant changes** with a `# SECURITY:` comment explaining the decision.

## Resilience Rules

- **Never silently swallow errors.** If a command can fail and the failure is acceptable, document why with a comment and capture the exit code explicitly — do not use `|| true` as a shortcut.
- **Use `wait_for_service` after starting services.** Do not assume a service is ready immediately after `systemctl start`.
- **`download_secure` already retries.** Do not add redundant retry loops around it. For other network calls, implement retries with exponential backoff.
- **Check disk space before large operations.** Use `check_disk_space` before any operation that writes significant data (backups, package installs on constrained systems).
- **Restore on failure.** Any script that overwrites a config must restore the backup if a later step fails. Use the ERR trap for this.

## Risk and Change Management

- **For architectural changes** (touching `install.sh`, `lib/`, or the stage model): describe the proposed design, list risks, and wait for confirmation before writing code.
- **Prefer small, reversible changes.** A script that adds one feature and is easy to revert is better than one that changes multiple behaviors at once.
- **Document trade-offs explicitly.** If a shortcut is taken for a good reason, write a comment in the code explaining the trade-off, not just what the code does.
- **Dangerous operations** (wiping mount points, dropping cron blocks, removing users) require a `# RISK:` comment with a clear explanation of what could go wrong and how it is mitigated.
- **Never generate destructive migrations without a rollback plan.** If a change alters `fstab`, crontab, or service configs, the script must be able to restore the previous state via the backup created by `create_backup`.

## Default Working Process

When given a task, follow this sequence:

1. **Read relevant files first.** Understand the existing code before proposing changes. Summarize any constraints or risks you find.
2. **Propose a plan** for non-trivial changes: what will change, why, and what could go wrong (security, resilience, idempotency impact).
3. **Implement in small steps**, explaining how each step respects the rules above.
4. **Verify dry-run compatibility.** Confirm every new system-mutating call goes through `execute_cmd`.
5. **Suggest how to test the change**: which `--only` script to run, what to look for in the log output, and any manual checks on the target system.

## What Never to Do

- Do not use bare `echo` for status output — use log functions.
- Do not write `|| true` without an explanatory comment.
- Do not skip `set -euo pipefail` or remove ERR traps.
- Do not introduce network calls outside of `download_secure` or `wait_for_service` without justification.
- Do not write permissions broader than necessary (`777`, `666`).
- Do not modify `.env.example` to include real credentials.
- Do not change the `BEGIN CONFIRASPA`/`END CONFIRASPA` markers or the cron isolation model without a design discussion.
- Do not bypass `execute_cmd` to run system commands directly, even in "simple" cases.
