# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Planned
- HTML report output
- Email notification on completion
- AWS/GCP/Azure cloud instance pre-checks
- Auto-remediation for common MEDIUM-risk issues
- Slack/webhook notification support

---

## [2.0.0] — 2024-12-01

### Added
- **Full system analysis suite** across 10 categories: OS, boot, network, repos, packages, services, security, users, applications, disk space
- **Block-device disk image backup** (`dd`) with MD5 integrity verification (first 512 MB)
- Backup metadata file with timestamped restore instructions
- **4-tier risk scoring system**: CRITICAL / HIGH / MEDIUM / LOW with per-item counters
- **Risk gate**: Prompts to abort if CRITICAL issues detected; warns on HIGH
- Detection for: PHP (version + mod_php vs php-fpm), Python 2, MySQL 5.x, MariaDB, PostgreSQL, Apache, Nginx, Java, Node.js, Docker, Kubernetes, SCL, Ansible/Puppet/Chef/Salt, OpenVPN, WireGuard, LUKS, SSSD/FreeIPA, fail2ban, AIDE, auditd
- **Software Collections (SCL) detection** with HIGH risk flag (SCL not supported in EL8)
- **Custom kernel module detection** in `/lib/modules/extra/`
- **Broken shared library** pre-scan (`ldd` on system binaries)
- Third-party repo detection with per-repo risk flags (Percona, Remi, IUS, Webtatic, Elastic)
- UEFI vs BIOS boot detection
- LVM full analysis (pvs/vgs/lvs)
- Software RAID (`mdstat`) detection
- Network bonding/teaming detection
- SELinux status with upgrade impact note
- firewalld vs iptables detection
- Config backup of all critical `/etc/` directories pre-upgrade
- Package snapshot (before/after delta comparison)
- **leapp inhibitor detection** — parses `leapp-report.txt` and blocks on inhibitors
- Automatic leapp answerfile entries for common prompts
- **Post-upgrade validation mode** (`--post-upgrade`): OS version, kernel, services, network, DNS, package delta, `.rpmsave`/`.rpmnew` detection
- **Future upgrade path analysis** section: EL8 → EL9 guide with breaking changes and EOL timeline
- Full timestamped audit log (tee'd to `/var/log/el8-migration/`)
- Structured migration report saved to disk
- `--analyze-only` mode (read-only, no changes)
- `--auto-yes` non-interactive mode for CI/CD pipelines
- `--log-dir` custom log directory
- `pv` support for progress bar during backup (falls back to `dd status=progress`)
- `numfmt` for human-readable disk size display

### Changed
- Complete rewrite from v1.0.0 — modular function-per-analysis-area architecture
- Risk reporting now uses named functions: `log_critical`, `log_high`, `log_warn`, `log_low`
- Backup now includes destination size validation before starting

### Fixed
- LVM disk detection now correctly strips partition suffixes for multi-PV setups
- `set -euo pipefail` applied globally for fail-fast safety

---

## [1.0.0] — 2024-06-15

### Added
- Initial release
- Basic CentOS 7 detection
- `yum update` + `leapp upgrade` wrapper
- Simple disk space check
- Basic service listing
- Rudimentary backup via `dd` without verification

---

[Unreleased]: https://github.com/YOUR_ORG/centos7-el8-migrate/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/YOUR_ORG/centos7-el8-migrate/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/YOUR_ORG/centos7-el8-migrate/releases/tag/v1.0.0
