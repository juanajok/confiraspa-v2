# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Confiraspa V2** is a fully bash-based provisioning framework for Raspberry Pi OS (Bookworm/Bullseye). It automates setting up a home production server (NAS, media server, torrent client, cloud backups, etc.) with a focus on idempotency, security, and structured logging.

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

There is no build system, test suite, or linter. All scripts are pure bash.

## Architecture

### Entry Points

- **`bootstrap.sh`** — One-time setup: installs `git`, `jq`, `curl`, makes scripts executable, creates `.env` from `.env.example`.
- **`install.sh`** — Main orchestrator. Loads `.env`, iterates through the `STAGES` array, runs each script in a subprocess. Supports `--dry-run` and `--only` filters. Creates a timestamped log in `logs/`.

### Shared Libraries (`lib/`)

All scripts source these at the top. Read them before modifying logging or command execution behavior.

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

Every script receives `--dry-run` from `install.sh`. The `execute_cmd` wrapper echoes commands with `[DRY-RUN]` instead of running them. Use `execute_cmd` for all system-mutating calls.

### Idempotency

Scripts check existing state before acting: `dpkg -l` before installing packages, file diffs before overwriting configs, `systemctl is-active` before restarting services.

### Error Handling

Scripts use `set -euo pipefail` and a trap on `ERR` that calls the error handler with `${BASH_LINENO[0]}`. Critical file writes back up originals via `create_backup` and restore on failure.

### JSON-Driven Operations

Maintenance scripts (`backup_cloud.sh`, `cleanup_backups.sh`, `restore_apps.sh`) iterate over JSON arrays using `jq`. Follow the same pattern when adding new jobs.

### Cron Management (`40-maintenance/cron.sh`)

Uses `BEGIN CONFIRASPA`/`END CONFIRASPA` markers in the system crontab to isolate managed tasks. Replaces only the Confiraspa block, leaving user-added entries intact.

### Logging

All output goes through `lib/utils.sh` log functions. These write colored output to stderr and plain text to the current run's log file in `logs/`. Never use bare `echo` for status messages.
