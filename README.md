# CentOS 7 → EL8 Migration Toolkit

A modular, production-safe toolkit for migrating CentOS 7 systems to **AlmaLinux 8** or **Rocky Linux 8** using the [ELevate](https://wiki.almalinux.org/elevate/) project.

**Version 3.0** — complete redesign with assessment-first workflow, menu-driven phases, resilient error handling, and state persistence.

---

## Key Design Principles

| v2.x (old) | v3.0 (new) |
|---|---|
| `set -e` — any error kills the script | No `set -e` — errors collected, not fatal |
| Linear execution, no recovery | Phase-based with state persistence — resume after failure |
| No pre-flight gate | Assessment phase first — shows GO/NO-GO before any changes |
| Errors logged but not summarised | Blockers / Warnings / Auto-fixes reported separately |
| Single run mode | Four modes: assess, fix, migrate, post-upgrade |

---

## Quick Start

```bash
# 1. Download and make executable
chmod +x centos7_to_el8_migrate.sh

# 2. Run interactive menu (recommended)
sudo ./centos7_to_el8_migrate.sh

# Or jump straight to assessment
sudo ./centos7_to_el8_migrate.sh --assess
```

---

## Modes

### Interactive Menu (default)
```bash
sudo ./centos7_to_el8_migrate.sh
```
Launches a menu with numbered options. Shows current migration progress on every screen.

```
  1) Assess       — Preflight check (read-only, no changes)
  2) Fix          — Auto-fix safe issues found by assessment
  3) Migrate      — Full migration wizard (phase by phase)
  4) Post-upgrade — Validate after upgrade completes
  5) View report  — Open last preflight report
  6) Reset state  — Clear saved progress
  0) Exit
```

### `--assess` — Preflight check only
```bash
sudo ./centos7_to_el8_migrate.sh --assess
```
Runs all checks. **Zero changes made to the system.** Produces a colour-coded report:

| Symbol | Meaning |
|---|---|
| ✔ PASS | Check passed |
| ℹ INFO | Informational, no action needed |
| ⚙ AUTO-FIX | Will be fixed automatically during migration |
| ⚠ WARN | Should review before proceeding |
| ✖ BLOCK | Must fix — migration cannot proceed |

Exit codes: `0` = GO, `1` = warnings, `2` = blockers.

### `--fix` — Auto-fix safe issues
```bash
sudo ./centos7_to_el8_migrate.sh --fix
```
Applies all safe, non-destructive fixes:
- Disables broken IPv6 (prevents leapp nspawn repo failures)
- Removes old kernels to free `/boot`
- Removes ABRT packages (leapp transaction conflict) safely (no cascade removal)
- Installs missing required tools
- Fixes `/etc/redhat-release` symlink on minimal installs

### `--migrate` — Full migration
```bash
# With backup device
sudo ./centos7_to_el8_migrate.sh --migrate --target alma --backup-dev /dev/sdb

# Rocky Linux, skip backup (if already backed up externally)
sudo ./centos7_to_el8_migrate.sh --migrate --target rocky --skip-backup
```

Runs assessment first. Blocks on any `BLOCK` findings. If blocked, fix the issues and re-run — the script **resumes from the last completed phase**.

### `--post-upgrade` — Post-reboot validation
```bash
sudo ./centos7_to_el8_migrate.sh --post-upgrade
```
Run this **after the system reboots** into EL8. Validates OS, services, network, EPEL, config conflicts, and prints the post-upgrade action checklist.

---

## Migration Phases

| Phase | Description | Resumable |
|---|---|---|
| 0. Preflight | Assessment — blockers, warnings, auto-fixes | — |
| 1. Target | Select AlmaLinux or Rocky Linux | ✔ |
| 2. Backup | Full disk image with MD5 verification | ✔ |
| 3. Prepare | yum update, remove conflicts, disable 3rd-party repos | ✔ |
| 4. ELevate | Install leapp packages, fix all inhibitors | ✔ |
| 5. Preupgrade | leapp preupgrade DRY RUN (auto-retries up to 3×) | ✔ |
| 6. Upgrade | leapp upgrade → system reboots (**POINT OF NO RETURN**) | — |

State is saved to `/var/log/el8-migration/.migration_state`. On re-run, completed phases are skipped automatically.

---

## Preflight Blockers

The script will refuse to migrate if any of these are found:

- Not CentOS 7
- Not running as root
- Less than 10GB free on `/`
- Less than 1GB free on `/boot`
- Cannot reach `repo.almalinux.org` (internet required)
- Software RAID array degraded

---

## Known Issues & Auto-Fixes

### IPv6 causes leapp repo failures
leapp bootstraps EL8 packages inside a `systemd-nspawn` container. The container inherits the host's network. If IPv6 is enabled but has no working connectivity, `dnf` tries IPv6 first, hangs for ~13 seconds per repo, and all repos fail to sync — producing:

```
Unable to install RHEL 8 userspace packages.
Failed to synchronize cache for repo 'almalinux8-baseos', ignoring this repo.
```

**Auto-fix**: The script detects broken IPv6 and disables it via `sysctl` (applied immediately + persisted to `/etc/sysctl.conf`).

### ABRT packages conflict with leapp
ABRT packages (`abrt`, `abrt-addon-*`, etc.) cause transaction conflicts with leapp. They must be removed before upgrade. However, standard `yum remove` triggers cascade removal of `leapp-upgrade-el7toel8` (via `libreport` dependency).

**Auto-fix**: Uses `--setopt=clean_requirements_on_remove=0` to remove only ABRT without cascade. Includes a safety check that reinstalls leapp if it was accidentally removed.

### leapp binary missing after package install
The `leapp` binary is provided by the `leapp` RPM package — **separate from** `leapp-upgrade-el7toel8`. On some ELevate versions only the upgrade package gets installed, leaving no binary.

**Auto-fix**: 6-stage binary resolver: checks known paths, PATH, filesystem search, RPM file lists, and attempts to install provider packages before giving up.

---

## Requirements

- CentOS 7.x (any minor version)
- Root / sudo access
- Internet access to `repo.almalinux.org`
- ≥10GB free on `/`
- ≥1GB free on `/boot`
- For backup: an additional block device at least as large as the source disk

**No host dependencies beyond what ships with CentOS 7.** The script installs everything it needs.

---

## Logs & Artifacts

All files written to `/var/log/el8-migration/` (or `--log-dir`):

| File | Contents |
|---|---|
| `migration_TIMESTAMP.log` | Full timestamped log of everything |
| `preflight_report_TIMESTAMP.txt` | Preflight assessment report |
| `packages_before_TIMESTAMP.txt` | Package snapshot before upgrade |
| `packages_after_TIMESTAMP.txt` | Package snapshot after upgrade |
| `config_backup_TIMESTAMP/` | Backup of critical config dirs |
| `backup_metadata_TIMESTAMP.txt` | Disk backup details + restore command |
| `leapp_preupgrade_*.log` | leapp preupgrade output |
| `leapp_upgrade_TIMESTAMP.log` | leapp upgrade output |
| `leapp_report_*.txt` | Copies of /var/log/leapp/leapp-report.txt |
| `.migration_state` | Phase completion state (resume support) |

---

## Post-Upgrade Checklist

After the system reboots into EL8:

```bash
# 1. Run post-upgrade validation
sudo ./centos7_to_el8_migrate.sh --post-upgrade

# 2. Set Python 3 as default
alternatives --set python /usr/bin/python3

# 3. Re-enable SELinux enforcing
sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
touch /.autorelabel && reboot

# 4. Security patches
dnf update --security -y

# 5. Rocky Linux only — enable CRB repo
dnf config-manager --enable crb

# 6. Re-enable third-party repos with EL8-compatible versions
# Review /etc/yum.repos.d/ — each disabled repo needs an EL8-compatible URL
```

---

## Tested On

- CentOS 7.7 / 7.8 / 7.9
- KVM virtual machines (BIOS boot)
- Target: AlmaLinux 8.10

---

## Roadmap

- [ ] UEFI real-hardware testing
- [ ] LVM thin pool support
- [ ] Support for CentOS Stream 8 → EL9 path
- [ ] Ansible role wrapper
- [ ] HTML report output

---

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).
