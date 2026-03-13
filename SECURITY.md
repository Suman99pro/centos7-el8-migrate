# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 3.x | ✔ Active |
| 2.x | ✖ No longer maintained |
| 1.x | ✖ No longer maintained |

## What This Script Does to Your System

This script makes the following changes when running `--migrate`:

**Non-destructive (assess / fix modes):**
- Reads system state, package lists, repos, logs
- May disable broken IPv6 via `sysctl` (reversible)
- May remove ABRT packages and old kernels (reversible)

**Prepare phase:**
- Runs `yum update -y` — updates all packages
- Removes conflicting packages (ABRT, SCL release RPMs)
- Disables third-party yum repos (re-enable post-upgrade)
- Backs up config directories to `/var/log/el8-migration/`

**ELevate phase:**
- Installs `elevate-release` RPM from `repo.almalinux.org`
- Installs `leapp`, `leapp-upgrade`, and distro data package
- Blacklists removed kernel drivers in `/etc/modprobe.d/`
- Modifies `/etc/sysctl.conf` if IPv6 is disabled

**Upgrade phase (POINT OF NO RETURN):**
- Runs `leapp upgrade` which replaces the OS in-place and reboots

## Reporting a Vulnerability

If you discover a security issue in this script (e.g. command injection via user input, unsafe use of temp files, privilege escalation), please open a GitHub issue marked `[SECURITY]`.

This is a sysadmin tool that requires root — the threat model is operator error and data loss, not remote code execution. Security issues are taken seriously but the primary concern is correctness and safety of the upgrade process.

## Verifying the Script

Before running, verify the script has not been tampered with:

```bash
# Check the script does not phone home or exfiltrate data
grep -E "curl|wget|nc |ncat" centos7_to_el8_migrate.sh

# The only outbound connections are:
# - curl to https://repo.almalinux.org (connectivity check)
# - yum install from https://repo.almalinux.org (ELevate RPM)
# - yum/dnf repo syncs during package installs
```
