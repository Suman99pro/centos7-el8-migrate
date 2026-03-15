# CentOS 7 → EL8 Migration Toolkit

Automates the migration of **CentOS 7** to **AlmaLinux 8** or **Rocky Linux 8** using the [ELevate project](https://wiki.almalinux.org/elevate/).

This script follows the **official AlmaLinux ELevate procedure** exactly, automating the manual steps required on a CentOS 7 Core/minimal install.

**References:**
- [ELevating CentOS 7 to AlmaLinux 8](https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html)
- [Migrate CentOS 7 to Rocky Linux](https://phoenixnap.com/kb/migrate-centos-to-rocky-linux)

---

## Prerequisites

- CentOS 7 (any variant — Core, Minimal, or full install)
- x86_64 architecture
- Root / sudo access
- Internet connection (to reach `repo.almalinux.org`)
- At least 5 GB free disk space on `/`

> **Note:** CentOS 7 reached end-of-life in June 2024. The script automatically
> switches your repos to AlmaLinux's CentOS 7 mirror or `vault.centos.org`
> if the official mirrors are unreachable.

---

## Quick Start

```bash
# Download
curl -O https://raw.githubusercontent.com/Suman99pro/centos7-el8-migrate/main/centos7_to_el8_migrate.sh
chmod +x centos7_to_el8_migrate.sh

# Migrate to AlmaLinux 8 (default)
sudo ./centos7_to_el8_migrate.sh

# Migrate to Rocky Linux 8
sudo ./centos7_to_el8_migrate.sh --target rocky

# Non-interactive
sudo ./centos7_to_el8_migrate.sh --target alma --auto-yes
```

---

## What the Script Does

Follows the 6 steps from the official ELevate guide:

| Step | Action |
|------|--------|
| 1 | Fix CentOS 7 repos (switch to vault/mirror — EOL) |
| 2 | `yum upgrade -y` to reach CentOS 7.9 |
| 3 | Pre-upgrade fixes: `pata_acpi`, SSH, ABRT, RHSM |
| 4 | Install `elevate-release` + `leapp-upgrade` + data package |
| 5 | `leapp preupgrade` — auto-fix inhibitors, retry up to 3x |
| 6 | `leapp upgrade` → system reboots automatically |

---

## Known Issues Fixed Automatically

### CentOS 7 EOL Repos
Official mirrors went offline in 2024. Script switches to:
- `https://el7.repo.almalinux.org/centos/CentOS-Base.repo` (primary)
- `vault.centos.org/7.9.2009` (fallback)

### NIC Disappearing During Upgrade
**Cause:** `systemd-nspawn` v219 (CentOS 7) [moves the host NIC into the container
namespace and never returns it](https://github.com/systemd/systemd/issues/4330).

**Fix:** Replaces `/usr/bin/systemd-nspawn` with a wrapper that adds
`--network-none` to every call. Original restored after upgrade.

### "Cannot set container mode for subscription-manager"
**Cause:** leapp calls `subscription-manager` even on non-RHEL systems.

**Fix:** Sets `LEAPP_NO_RHSM=1`, writes `/etc/rhsm/rhsm.conf` with
`manage_repos=0`, creates stub binary if absent.

### "Unable to install RHEL 8 userspace packages"
**Cause:** nspawn container (with `--network-none`) can't reach repos.

**Fix:** Pre-populates the EL8 installroot from the host before leapp runs.

---

## After the Upgrade

```bash
# Validate
sudo ./centos7_to_el8_migrate.sh --post-upgrade

# Set Python 3 as default
alternatives --set python /usr/bin/python3

# Re-enable SELinux
sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
touch /.autorelabel && reboot

# Update packages
dnf update -y

# Check leftover el7 packages
rpm -qa | grep el7
```

---

## Options

| Flag | Description |
|------|-------------|
| `--target alma` | Upgrade to AlmaLinux 8 (default) |
| `--target rocky` | Upgrade to Rocky Linux 8 |
| `--auto-yes`, `-y` | Skip confirmation prompts |
| `--post-upgrade` | Post-reboot validation |
| `--help` | Show usage |

---

## Logs

All logs: `/var/log/el8-migration/`

---

## License

MIT
