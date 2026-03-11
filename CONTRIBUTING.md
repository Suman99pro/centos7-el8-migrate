# Contributing to CentOS 7 → EL8 Migration Toolkit

Thank you for considering contributing! This project is used in production environments, so we hold contributions to a high standard of quality and safety.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How to Report Bugs](#how-to-report-bugs)
- [How to Request Features](#how-to-request-features)
- [Development Setup](#development-setup)
- [Submitting Pull Requests](#submitting-pull-requests)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Areas Welcoming Contributions](#areas-welcoming-contributions)

---

## Code of Conduct

This project follows a simple standard: **be respectful, be constructive, be helpful**.

- Critique code, not people
- Assume good faith in questions and contributions
- Keep discussions focused on technical merit

---

## How to Report Bugs

Before filing a bug, please check if it is already reported in [Issues](../../issues).

When reporting, please include:

```
**Script Version:** (from --version or the header)
**CentOS Version:** (cat /etc/centos-release)
**Target Distro:** AlmaLinux 8 / Rocky Linux 8
**Virtualisation:** (systemd-detect-virt)
**Storage Type:** LVM / bare disk / RAID
**Description:** What happened vs what was expected
**Reproduce:** Exact command used
**Log excerpt:** Relevant lines from /var/log/el8-migration/*.log
```

> **Never paste actual server IP addresses, passwords, or sensitive data in issues.**

---

## How to Request Features

Open an issue with the tag `enhancement` and describe:

1. The problem or gap you're experiencing
2. The proposed solution
3. Whether you're willing to implement it

---

## Development Setup

### Prerequisites

- A CentOS 7 VM or test environment (do **not** develop on production)
- `shellcheck` for static analysis
- `bash` 4.4+

### Setup

```bash
# Clone the repository
git clone https://github.com/YOUR_ORG/centos7-el8-migrate.git
cd centos7-el8-migrate

# Install shellcheck (on Fedora/RHEL/CentOS)
yum install -y shellcheck   # or: dnf install -y shellcheck

# On macOS (for local syntax checking)
brew install shellcheck

# Run syntax check
bash -n centos7_to_el8_migrate.sh

# Run shellcheck
shellcheck centos7_to_el8_migrate.sh
```

### Recommended Test Environment

```
- CentOS 7.9 VM (minimum 20GB disk, 2GB RAM)
- A secondary virtual disk (/dev/sdb) for backup testing
- Snapshots enabled in your hypervisor
- Internet access for leapp package downloads
```

---

## Submitting Pull Requests

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```bash
   git checkout -b fix/describe-your-fix
   # or
   git checkout -b feat/describe-your-feature
   ```
3. **Make your changes** (see Coding Standards below)
4. **Run tests** (see Testing below)
5. **Commit** with a clear message:
   ```
   fix: correct LVM source disk detection for multi-PV setups
   feat: add detection for HAProxy and keepalived
   docs: clarify /boot space requirement in README
   ```
6. **Push** and open a Pull Request against `main`

### PR Checklist

- [ ] `bash -n` passes (no syntax errors)
- [ ] `shellcheck` passes with no warnings
- [ ] Tested on at least CentOS 7.9 (VM/snapshot)
- [ ] `--analyze-only` mode does not modify the system
- [ ] New risk detections include the correct risk level (`log_high`, `log_warn`, `log_low`)
- [ ] Log messages are clear and actionable
- [ ] README updated if new flags, behaviour, or compatibility is added
- [ ] CHANGELOG updated under `[Unreleased]`

---

## Coding Standards

### Shell Style

```bash
# Always use:
set -euo pipefail
IFS=$'\n\t'

# Quote all variables
local result="$some_var"

# Use [[ ]] not [ ] for conditions
if [[ "$var" == "value" ]]; then

# Local variables in functions
my_function() {
    local my_var="value"
}

# Readonly for constants
readonly SCRIPT_VERSION="2.0.0"
```

### Risk Logging

Use the correct severity function:

```bash
log_critical "..."  # Upgrade will fail or cause data loss — must fix
log_high "..."      # Application will likely break — fix before upgrading
log_warn "..."      # May need attention — MEDIUM risk
log_low "..."       # Informational — LOW risk
log_ok "..."        # All clear
log_info "..."      # Neutral information
```

### Analysis Functions

All analysis functions should:
- Be **read-only** (no system modifications)
- Use `log_*` to report findings with appropriate severity
- Echo section headers with `log_section`
- Handle command-not-found gracefully with `command -v foo &>/dev/null || return`

```bash
analyze_myservice() {
    log_section "MyService Analysis"

    if ! command -v myservice &>/dev/null; then
        return 0  # Not installed, nothing to check
    fi

    local version
    version=$(myservice --version 2>/dev/null | head -1 || echo "unknown")
    log_info "MyService detected: $version"

    if echo "$version" | grep -q "1\."; then
        log_high "MyService v1.x is not compatible with EL8. Upgrade to v2.x first."
    fi
}
```

---

## Testing

### Syntax Test

```bash
bash -n centos7_to_el8_migrate.sh && echo "OK"
shellcheck centos7_to_el8_migrate.sh
```

### Functional Tests (on CentOS 7 VM with snapshot)

```bash
# Test 1: Analysis only — must make zero changes
sudo ./centos7_to_el8_migrate.sh --analyze-only
# Verify: no packages installed/removed, no files modified outside /var/log/el8-migration/

# Test 2: Help output
./centos7_to_el8_migrate.sh --help

# Test 3: Invalid args
./centos7_to_el8_migrate.sh --target invalid 2>&1 | grep -q "Unknown\|Invalid" && echo "PASS"

# Test 4: Non-root rejection
bash centos7_to_el8_migrate.sh --analyze-only 2>&1 | grep -q "root" && echo "PASS"

# Test 5: Backup size validation (backup device smaller than source)
# Set BACKUP_DEV to a smaller device and confirm the script aborts with an error
```

### Test Matrix

| CentOS Version | Bare Disk | LVM | VM | Bare Metal |
|---|---|---|---|---|
| 7.6 | ✅ | ✅ | ✅ | Recommended |
| 7.7 | ✅ | ✅ | ✅ | Recommended |
| 7.8 | ✅ | ✅ | ✅ | Recommended |
| 7.9 | ✅ | ✅ | ✅ | Recommended |

---

## Areas Welcoming Contributions

| Area | Description |
|---|---|
| **More app detection** | HAProxy, Varnish, Redis Cluster, Cassandra, Elasticsearch, Vault |
| **Cloud support** | AWS/GCP/Azure specific pre-checks (instance metadata, cloud agents) |
| **Email notifications** | Send report via sendmail/mailx on completion |
| **HTML report** | Convert the text report to a styled HTML output |
| **Pre-upgrade fixers** | Auto-remediation for known MEDIUM-risk issues |
| **leapp answer automation** | Auto-populate more leapp answerfile entries |
| **systemd service restart** | Post-upgrade service restart and health check loop |
| **Slack/Webhook integration** | Notify a channel on completion or failure |

---

Thank you for helping make this tool safer and more useful for the Linux community! 🐧
