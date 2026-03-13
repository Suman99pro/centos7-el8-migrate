# Contributing to CentOS 7 → EL8 Migration Toolkit

Thank you for your interest in contributing!

## How to Contribute

### Reporting Bugs

Before opening an issue, please collect:

```bash
# Attach these to your bug report
cat /var/log/el8-migration/migration_*.log | tail -100
cat /var/log/el8-migration/preflight_report_*.txt
cat /var/log/leapp/leapp-report.txt 2>/dev/null
cat /etc/centos-release
uname -r
rpm -qa | grep -iE "leapp|elevate"
```

Include:
- CentOS minor version (7.6 / 7.7 / 7.8 / 7.9)
- Bare metal or VM (and hypervisor type)
- BIOS or UEFI
- LVM / software RAID / standard partitioning
- Target distro (AlmaLinux or Rocky Linux)
- Which phase failed

### Pull Requests

1. Fork the repository
2. Create a branch: `git checkout -b fix/description` or `feat/description`
3. Test on a CentOS 7 VM before submitting
4. Update `CHANGELOG.md` under `[Unreleased]`
5. Open a PR with a description of what was tested

### Testing

The script is designed to be tested on a disposable CentOS 7 VM. A minimal test run:

```bash
# Assessment only — safe on any CentOS 7 system, no changes made
sudo ./centos7_to_el8_migrate.sh --assess

# Auto-fix only
sudo ./centos7_to_el8_migrate.sh --fix
```

Full migration tests should only be run on a VM with a snapshot or backup.

### Code Style

- Bash 4+ compatible
- No `set -e` — handle errors explicitly
- Functions return exit codes; use `die()` only for truly unrecoverable errors
- All changes to the system go through a phase function with state tracking
- Every phase must be idempotent (safe to re-run)
- Log every action: `log_info` before, `log_ok` or `log_warn` after

### Scope

In scope:
- CentOS 7.x → AlmaLinux 8 / Rocky Linux 8
- Bug fixes for specific hardware/software configurations
- New preflight checks
- Improved inhibitor remediation

Out of scope (for now):
- CentOS 8 / Stream migrations
- EL8 → EL9 (separate tooling)
- Non-x86_64 architectures
