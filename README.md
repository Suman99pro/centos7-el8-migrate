# 🚀 CentOS 7 → AlmaLinux 8 / Rocky Linux 8 Migration Toolkit

<div align="center">

![Version](https://img.shields.io/badge/version-2.0.0-blue?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash%205%2B-green?style=flat-square)
![CentOS](https://img.shields.io/badge/source-CentOS%207.x-262577?style=flat-square&logo=centos)
![AlmaLinux](https://img.shields.io/badge/target-AlmaLinux%208-0ea5e9?style=flat-square)
![Rocky](https://img.shields.io/badge/target-Rocky%20Linux%208-10b981?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square)

**A production-grade, fully automated in-place OS migration script with deep analysis, block-device backup, risk scoring, and post-upgrade validation.**

[Quick Start](#-quick-start) · [Features](#-features) · [Usage](#-usage) · [Architecture](#-architecture) · [FAQ](#-faq) · [Contributing](CONTRIBUTING.md)

</div>

---

## ⚠️ Important Disclaimer

> **Always test on a non-production clone before running on live systems.**
> This script performs an **irreversible in-place operating system upgrade**.
> The authors accept no liability for data loss, downtime, or service disruption.
> A verified block-device backup is **strongly recommended** before proceeding.

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Features](#-features)
- [Requirements](#-requirements)
- [Quick Start](#-quick-start)
- [Usage](#-usage)
- [Architecture & Phases](#-architecture--phases)
- [What Gets Analyzed](#-what-gets-analyzed)
- [Risk Scoring System](#-risk-scoring-system)
- [Backup & Restore](#-backup--restore)
- [Known Incompatibilities](#-known-incompatibilities)
- [Future Upgrade Path](#-future-upgrade-path-el8--el9)
- [Log Files & Reports](#-log-files--reports)
- [FAQ](#-faq)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Changelog](CHANGELOG.md)

---

## 🔭 Overview

CentOS Linux 7 reached **End of Life on June 30, 2024**. This toolkit provides a safe, auditable, production-ready migration path to either **AlmaLinux 8** or **Rocky Linux 8** using the [ELevate project](https://wiki.almalinux.org/elevate/) (powered by `leapp`).

The script guides you through every stage:

```
CentOS 7.x
   │
   ├─ [Phase 1] Deep system analysis & risk scoring
   ├─ [Phase 2] Full disk image backup with integrity verification
   ├─ [Phase 3] Pre-upgrade preparation & cleanup
   ├─ [Phase 4] ELevate in-place upgrade (leapp)
   ├─ [Phase 5] Post-upgrade validation
   │
   └─▶ AlmaLinux 8  OR  Rocky Linux 8
            │
            └─▶ (Future) AlmaLinux 9 / Rocky Linux 9
```

---

## ✨ Features

| Category | What's Included |
|---|---|
| 🔍 **Analysis** | OS, hardware, boot, storage, network, repos, packages, services, security, users, dependencies |
| 🎯 **Risk Scoring** | 4-tier risk system (CRITICAL / HIGH / MEDIUM / LOW) with per-item flagging |
| 💾 **Backup** | `dd` block-device image with MD5 integrity verification + restore instructions |
| 🔧 **Preparation** | Full CentOS 7 update, conflict removal, kernel cleanup, config backup |
| 🚀 **Upgrade** | ELevate/leapp dry-run + inhibitor detection + live upgrade |
| ✅ **Validation** | Post-upgrade OS, services, network, DNS, package delta, config conflict checks |
| 🔮 **Future Path** | EL8 → EL9 upgrade guide and breaking changes analysis |
| 📝 **Audit Trail** | Full timestamped log + structured migration report |

---

## 📦 Requirements

### Source System
| Requirement | Detail |
|---|---|
| **OS** | CentOS Linux 7.6, 7.7, 7.8, or 7.9 |
| **Privileges** | `root` (or `sudo`) |
| **Shell** | Bash 4.4+ |
| **Architecture** | x86\_64 only |
| **Free disk (`/`)** | ≥ 10 GB |
| **Free disk (`/boot`)** | ≥ 1 GB |
| **RAM** | ≥ 1 GB (2 GB+ recommended) |
| **Internet access** | Required (to download leapp packages) |

### For Backup (Optional but Recommended)
| Requirement | Detail |
|---|---|
| **Block device** | `/dev/sdX`, `/dev/vdX`, or similar — size ≥ source disk |
| **`pv`** | Optional, for progress bar (`yum install pv`) |

### Tools (auto-installed if missing)
`rpm`, `yum`, `lsblk`, `df`, `free`, `uname`, `ss`, `lsof`, `ip`, `awk`, `grep`, `sed`, `curl`

---

## ⚡ Quick Start

```bash
# 1. Download the script
curl -O https://raw.githubusercontent.com/suman99pro/centos7-el8-migrate/main/centos7_to_el8_migrate.sh

# 2. Make it executable
chmod +x centos7_to_el8_migrate.sh

# 3. Run analysis only first (safe — no changes)
sudo ./centos7_to_el8_migrate.sh --analyze-only

# 4. Review the report, then run the full migration
sudo ./centos7_to_el8_migrate.sh --target alma --backup-dev /dev/sdb

# 5. After reboot and upgrade completes, run post-upgrade validation
sudo ./centos7_to_el8_migrate.sh --post-upgrade
```

---

## 🛠 Usage

```
Usage: centos7_to_el8_migrate.sh [OPTIONS]

Options:
  --target   alma|rocky      Target distribution (default: interactive prompt)
  --backup-dev /dev/sdX      Block device for full disk image backup
  --skip-backup              Skip backup step — NOT recommended
  --analyze-only             Run full analysis and generate report, no changes
  --auto-yes                 Non-interactive mode (USE WITH CAUTION in CI/CD)
  --log-dir /path            Custom log directory (default: /var/log/el8-migration)
  --post-upgrade             Run post-upgrade validation after system reboots
  -h, --help                 Show help
```

### Examples

```bash
# === ANALYSIS ONLY (safest — no changes made) ===
sudo ./centos7_to_el8_migrate.sh --analyze-only

# === AlmaLinux 8 with backup to /dev/sdb ===
sudo ./centos7_to_el8_migrate.sh --target alma --backup-dev /dev/sdb

# === Rocky Linux 8, skip backup (already have external snapshot) ===
sudo ./centos7_to_el8_migrate.sh --target rocky --skip-backup

# === Non-interactive (CI/CD pipelines, automation) ===
sudo ./centos7_to_el8_migrate.sh --target alma --backup-dev /dev/sdb --auto-yes

# === Custom log directory ===
sudo ./centos7_to_el8_migrate.sh --analyze-only --log-dir /opt/migration-logs

# === Post-upgrade validation (run after system reboots) ===
sudo ./centos7_to_el8_migrate.sh --post-upgrade
```

---

## 🏗 Architecture & Phases

### Phase 1 — System Analysis (read-only)

The entire analysis phase is **non-destructive**. Nothing is modified. It produces a structured report with risk scores.

```
analyze_system()           → OS, kernel, CPU, RAM, uptime, virtualisation, SELinux, firewall
analyze_boot()             → Bootloader (UEFI/BIOS), fstab, LVM, RAID, network FS
analyze_network()          → IPs, routes, DNS, bonding/teaming, listening ports
analyze_repositories()     → Enabled repos, third-party repo detection
analyze_installed_packages()→ PHP, Python, MySQL, MariaDB, Java, Node.js, Docker, K8s, SCL
analyze_services()         → systemd services, cron jobs, timers
analyze_security()         → SSH, SELinux, LUKS, PAM, sudoers, IDS tools
analyze_users()            → Local users, SSSD/LDAP/FreeIPA
analyze_applications_deep()→ Third-party packages, broken shlibs, SCL, key config files
check_disk_space_for_upgrade()→ / and /boot space validation
```

### Phase 2 — Block Device Backup

```bash
# What the script does internally:
dd if=/dev/sda of=/dev/sdb bs=4M conv=noerror,sync status=progress

# Then verifies with:
md5sum <(dd if=/dev/sda bs=1M count=512) == md5sum <(dd if=/dev/sdb bs=1M count=512)
```

Backup metadata (source disk, size, duration, MD5, restore command) is saved to:
```
/var/log/el8-migration/backup_metadata_TIMESTAMP.txt
```

### Phase 3 — Pre-Upgrade Preparation

1. `yum update -y` — brings CentOS 7 fully up to date
2. Removes conflicting packages (ABRT, SCL meta-packages, python2-virtualenv)
3. Removes old kernels (`package-cleanup --oldkernels --count=1`)
4. Installs EPEL if missing
5. Disables third-party repos for clean leapp upgrade
6. Backs up critical config directories to `/var/log/el8-migration/config_backup_TIMESTAMP/`
7. Snapshots the full package list to `packages_before_TIMESTAMP.txt`

### Phase 4 — ELevate Upgrade

Uses the [ELevate project](https://wiki.almalinux.org/elevate/):

```
leapp preupgrade   → Dry-run: checks for inhibitors
leapp upgrade      → Live upgrade: system reboots into initramfs upgrade environment
```

The script parses `leapp-report.txt` and blocks on **inhibitors** — issues that would cause the upgrade to fail.

### Phase 5 — Post-Upgrade Validation

Run after the system reboots back into the new OS:

```bash
sudo ./centos7_to_el8_migrate.sh --post-upgrade
```

Checks:
- New OS version confirmed (AlmaLinux 8 / Rocky Linux 8)
- Kernel version
- Critical services (sshd, NetworkManager, rsyslog, crond)
- Failed systemd units
- Network and DNS connectivity
- Package delta (added/removed packages)
- `.rpmsave` / `.rpmnew` config conflicts
- EPEL for EL8

---

## 🔎 What Gets Analyzed

### Application Stack Detection

| Technology | What's Checked | Risk if Detected |
|---|---|---|
| **PHP** | Version (5.x / 7.0 / 7.1) | 🔴 HIGH — EOL, not in EL8 AppStream |
| **PHP** | mod_php vs php-fpm | 🟡 MEDIUM — Reconfiguration needed |
| **Python 2** | Any python2 packages | 🔴 HIGH — Removed in EL8 |
| **MySQL Server** | 5.x presence | 🔴 HIGH — Not in EL8 repos |
| **MariaDB** | Version | 🟡 MEDIUM — EL8 ships 10.3 |
| **PostgreSQL** | Any version | 🟡 MEDIUM — Verify repo |
| **Apache HTTPD** | Version | 🟢 LOW — 2.4 compatible |
| **Nginx** | Version | 🟢 LOW — Available in EL8 |
| **Java** | 6/7/8 detection | 🔴 HIGH — Verify app compat |
| **Node.js** | SCL-installed | 🟡 MEDIUM — Switch to AppStream module |
| **Docker** | Version / daemon | 🟡 MEDIUM — Reinstall from EL8 repo |
| **Kubernetes** | kubelet / kubectl | 🔴 HIGH — Upgrade after OS migration |
| **SCL packages** | Any rh-* / devtoolset-* | 🔴 HIGH — SCL not supported in EL8 |
| **Config mgmt** | Ansible/Puppet/Chef/Salt | 🟡 MEDIUM — Reinstall from EL8 repos |
| **VPN** | OpenVPN / WireGuard | 🟡 MEDIUM — Verify kernel module |
| **Custom kernel modules** | /lib/modules/extra/ | 🔴 HIGH — Will NOT work with EL8 kernel |

### Infrastructure & OS

| Area | What's Checked |
|---|---|
| **Boot** | UEFI vs BIOS, GRUB2 config |
| **Storage** | LVM (pvs/vgs/lvs), RAID (mdstat), LUKS encryption |
| **Network** | Bond/team interfaces, NetworkManager vs legacy scripts |
| **Repos** | Remi, Percona, IUS, Webtatic, MariaDB, MySQL, Elastic flagged |
| **SELinux** | Enforcing/Permissive/Disabled |
| **Firewall** | firewalld vs iptables |
| **Auth** | SSSD, LDAP, FreeIPA, PAM |
| **Security** | fail2ban, AIDE, OSSEC, Tripwire |
| **Audit** | auditd rules |
| **Shared libs** | `ldd` scan of system binaries for pre-existing broken links |

---

## 🎯 Risk Scoring System

Every detected issue is tagged with a risk level:

| Level | Colour | Meaning | Action Required |
|---|---|---|---|
| `CRITICAL` | 🔴 Red | Will cause upgrade failure or data loss | **Must fix before upgrading** |
| `HIGH` | 🟠 Orange | Will likely break application functionality | Fix before upgrading |
| `MEDIUM` | 🟡 Yellow | May need manual attention post-upgrade | Review and plan |
| `LOW` | 🔵 Blue | Minor impact, informational | Awareness only |
| `OK` | 🟢 Green | No issue detected | — |

The script enforces a **risk gate** before proceeding:
- **CRITICAL** issues → Prompts to abort (default)
- **HIGH** issues → Prompts for confirmation
- **MEDIUM/LOW** → Proceeds with warnings

---

## 💾 Backup & Restore

### Creating the Backup

```bash
sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb
```

The script will:
1. Detect source disk (works with LVM)
2. Validate destination size ≥ source
3. Sync filesystem (`sync` + drop caches)
4. Run `dd` with progress
5. Verify integrity via MD5 (first 512 MB)
6. Save restore instructions to log

### Restoring from Backup

```bash
# Boot from a live USB/CD, then:
dd if=/dev/sdb of=/dev/sda bs=4M conv=noerror,sync status=progress

# After restore, fix bootloader:
grub2-install /dev/sda
grub2-mkconfig -o /boot/grub2/grub.cfg
```

> The exact restore command is also saved in `/var/log/el8-migration/backup_metadata_*.txt`

### Alternative Backup Strategies

| Method | Command | Notes |
|---|---|---|
| Block device (this script) | `dd if=/dev/sda of=/dev/sdb ...` | Full bare-metal restore |
| LVM snapshot | `lvcreate -L10G -s -n snap /dev/vg0/root` | Fast, same-disk snapshot |
| Cloud snapshot | AWS/GCP/Azure console | For cloud instances |
| Filesystem backup | `rsync -axHAX / /mnt/backup/` | File-level, no bootloader |

---

## ⚡ Known Incompatibilities (EL7 → EL8)

### Removed / Changed in EL8

| Component | EL7 | EL8 | Action |
|---|---|---|---|
| Python default | Python 2.7 | Python 3.6 | Port Python 2 scripts |
| PHP | 5.4 (base) | 7.2, 7.4, 8.0 (AppStream) | Use AppStream modules |
| MySQL | 5.7 (via SCL) | 8.0 | Migrate data, update app config |
| MariaDB | 5.5 (base) | 10.3, 10.5 (AppStream) | Verify charset/collation |
| Network scripts | `/etc/sysconfig/network-scripts/` (ifcfg) | NetworkManager preferred | Test interface config |
| iptables | Default | nftables backend | Review firewall rules |
| NTP | `ntpd` | `chronyd` | Reconfigure NTP |
| ABRT | Available | Removed | Use `systemd-coredump` |
| SCL | centos-release-scl | **Not supported** | Migrate to AppStream modules |
| `yum` | Default | `dnf` (yum is alias) | Update scripts/CI |
| Crypto policy | Per-service | System-wide (`update-crypto-policies`) | Review TLS versions |
| `ifconfig` / `netstat` | Default | Removed from base | Use `ip`, `ss` |
| `ntp` | Default | Removed | Use `chrony` |

### Repository Equivalents

| EL7 Repo | EL8 Equivalent |
|---|---|
| EPEL 7 | EPEL 8 (`dnf install epel-release`) |
| Remi (PHP) | Remi for EL8 |
| Percona | Percona EL8 repo |
| MySQL | MySQL EL8 repo |
| PostgreSQL | PostgreSQL EL8 repo (PGDG) |
| IUS | **Discontinued** — use AppStream modules |
| Webtatic | **Discontinued** — use AppStream modules |
| SCL | **Not supported** — use AppStream modules |

---

## 🔮 Future Upgrade Path (EL8 → EL9)

Once on EL8, the next upgrade to EL9 uses the same ELevate tooling:

```bash
# On AlmaLinux 8 / Rocky Linux 8:
dnf install -y https://repo.almalinux.org/elevate/elevate-release-latest-el8.noarch.rpm
dnf install -y leapp-upgrade leapp-data-almalinux   # or leapp-data-rocky
leapp preupgrade
# Fix inhibitors in /var/log/leapp/leapp-report.txt
leapp upgrade
# System reboots → AlmaLinux 9 / Rocky Linux 9
```

### EOL Timeline

| OS | End of Life |
|---|---|
| CentOS 7 | ~~2024-06-30~~ **EOL** |
| AlmaLinux 8 | 2029-03-01 |
| Rocky Linux 8 | 2029-05-31 |
| AlmaLinux 9 | 2032-05-31 |
| Rocky Linux 9 | 2032-05-31 |

### Key EL8 → EL9 Breaking Changes

- OpenSSL 3.0 (deprecated API removals)
- Minimum TLS 1.2 system-wide
- cgroups v2 as default
- nftables replaces iptables backend
- PHP 8.0/8.1/8.2 (no PHP 7.x in EL9)
- Python 3.9 default
- SHA-1 signature policy changes

---

## 📁 Log Files & Reports

All logs are written to `/var/log/el8-migration/` (configurable with `--log-dir`):

```
/var/log/el8-migration/
├── migration_20241201_143022.log          # Full timestamped execution log
├── migration_report_20241201_143022.txt   # Structured summary report
├── backup_metadata_20241201_143022.txt    # Backup details + restore command
├── leapp_preupgrade_20241201_143022.log   # leapp preupgrade output
├── leapp_report_20241201_143022.txt       # Copy of /var/log/leapp/leapp-report.txt
├── leapp_upgrade_20241201_143022.log      # leapp upgrade output
├── packages_before_20241201_143022.txt    # Pre-upgrade package list
├── packages_after_20241201_143022.txt     # Post-upgrade package list
└── config_backup_20241201_143022/         # Backed-up config directories
    ├── httpd/
    ├── nginx/
    ├── ssh/
    └── ...
```

---

## ❓ FAQ

**Q: Can I run this on CentOS Stream or RHEL?**
A: No. This script is designed exclusively for **CentOS Linux 7.x** (not CentOS Stream). RHEL has its own LEAPP upgrade path via Red Hat Satellite/Console.

**Q: Does this work on cloud instances (AWS, GCP, Azure)?**
A: Yes, with caveats. Cloud instances have ephemeral disks so skip `--backup-dev` and use a cloud snapshot instead. Some cloud-specific agents (AWS SSM, GCP guest agent) may need reinstallation post-upgrade. Boot disk backup via `dd` is not applicable for cloud VMs.

**Q: What happens if the upgrade fails mid-way?**
A: The system may be in a partially upgraded state. Boot from a rescue environment and restore from your block-device backup using the restore command in `backup_metadata_*.txt`.

**Q: Can I go directly from CentOS 7 to EL9?**
A: No. The supported path is CentOS 7 → EL8 → EL9 (two separate upgrades). Direct EL7 → EL9 is not supported by ELevate.

**Q: How long does the upgrade take?**
A: Typically 20–60 minutes depending on disk speed, number of packages, and hardware. The system reboots into the upgrade initramfs automatically.

**Q: Will my custom kernel modules work after upgrade?**
A: No. Custom kernel modules compiled for the EL7 kernel will NOT work with the EL8 kernel. You must recompile or source EL8-compatible DKMS packages.

**Q: Is `--auto-yes` safe for CI/CD pipelines?**
A: Use with caution. It bypasses all interactive confirmations including the final upgrade prompt. Recommended only in fully automated, pre-validated pipelines where you've already run `--analyze-only` and reviewed the report.

**Q: What's the difference between AlmaLinux 8 and Rocky Linux 8?**
A: Both are binary-compatible RHEL 8 rebuilds. AlmaLinux is backed by CloudLinux Inc.; Rocky Linux was founded by CentOS co-founder Gregory Kurtzer. Both have similar package availability and long-term support. Choose based on your organisation's preference.

**Q: Can I reverse the upgrade?**
A: In-place upgrades are not reversible without restoring from backup. There is no "downgrade" path from EL8 back to CentOS 7. This is why backup is critical.

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting issues, submitting pull requests, and extending the script.

---

## 🔐 Security

See [SECURITY.md](SECURITY.md) for the security policy and how to report vulnerabilities.

---

## 📜 License

[MIT License](LICENSE) — see the LICENSE file for details.

---

## 🙏 Acknowledgements

- [AlmaLinux ELevate Project](https://wiki.almalinux.org/elevate/)
- [leapp-upgrade](https://leapp.readthedocs.io/en/latest/) by Red Hat
- [Rocky Linux Migration Guide](https://docs.rockylinux.org/guides/migrate2rocky/)
- The CentOS and RHEL ecosystem community

---

<div align="center">

Made with ❤️ for the Linux sysadmin community.
**Star ⭐ this repo if it saved your production server.**

</div>
