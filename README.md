# CentOS 7 → EL8 Migration Toolkit

Automates the migration of **CentOS 7** to **AlmaLinux 8** or **Rocky Linux 8** using the [ELevate project](https://wiki.almalinux.org/elevate/), with full disk image backup and restore capability.

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
curl -O https://raw.githubusercontent.com/your-repo/centos7-el8-migrate/main/centos7_to_el8_migrate.sh
chmod +x centos7_to_el8_migrate.sh

# Recommended: migrate with backup to external drive
sudo ./centos7_to_el8_migrate.sh --target alma --backup-dev /dev/sdb

# Migrate with backup to a directory (NFS, local mount, etc.)
sudo ./centos7_to_el8_migrate.sh --target alma --backup-dir /mnt/nas/backups

# Migrate to Rocky Linux 8 with backup
sudo ./centos7_to_el8_migrate.sh --target rocky --backup-dev /dev/sdb
```

---

## Backup & Restore

Taking a backup before migration lets you restore the system to its exact original state if anything goes wrong.

### Backup Options

#### Option A — External Block Device (Recommended)

Writes a raw `dd` image of every system disk directly to an external drive.
This is the fastest and most reliable restore method.

```bash
# List available disks to find your backup drive
lsblk

# Back up to an external USB drive or second disk
sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb

# Backup only — no migration
sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb --backup-only
```

> **Warning:** All data on the backup device will be overwritten. Use a
> dedicated backup drive, not a drive with important data.

#### Option B — Compressed Image File

Writes a `gzip`-compressed image of each disk to a directory. Works with
NFS mounts, local storage, or any mounted filesystem.

```bash
# Back up to a mounted NFS share
sudo mount nas:/backups /mnt/nas
sudo ./centos7_to_el8_migrate.sh --backup-dir /mnt/nas

# Back up to a local path (ensure enough free space: ~1/3 of disk size)
sudo ./centos7_to_el8_migrate.sh --backup-dir /backup
```

Files created per disk:
```
/backup/centos7_sda_20260315_143022.img.gz      # compressed disk image
/backup/centos7_sda_20260315_143022.img.gz.md5  # MD5 checksum
/backup/centos7_sda_20260315_143022.restore.txt # restore instructions
```

### Restore

If migration fails and you need to restore:

```bash
# Interactive restore wizard
sudo ./centos7_to_el8_migrate.sh --restore
```

Or manually from a live CD/USB:

```bash
# From external block device
dd if=/dev/sdb of=/dev/sda bs=4M conv=noerror,sync status=progress

# From compressed image file
# First verify integrity:
md5sum -c centos7_sda_20260315_143022.img.gz.md5
# Then restore:
gunzip -c centos7_sda_20260315_143022.img.gz | \
    dd of=/dev/sda bs=4M conv=noerror,sync status=progress

# Rebuild bootloader after restore (if needed)
grub2-install /dev/sda
grub2-mkconfig -o /boot/grub2/grub.cfg
```

---

## Migration Steps

The script follows the official ELevate guide with these 7 steps:

| Step | Action |
|------|--------|
| 0 | Pre-flight checks (OS, arch, network, disk space) |
| 1 | **Disk image backup** (full raw backup of all disks) |
| 2 | Fix CentOS 7 repos (switch to vault/mirror — EOL) |
| 3 | `yum upgrade -y` to reach CentOS 7.9 |
| 4 | Pre-upgrade fixes: drivers, SSH, ABRT, RHSM |
| 5 | Install `elevate-release` + `leapp-upgrade` + data package |
| 6 | `leapp preupgrade` — auto-fix inhibitors, retry up to 3× |
| 7 | `leapp upgrade` → system reboots automatically |

---

## Known Issues Fixed Automatically

### CentOS 7 EOL Repos
Official mirrors went offline in 2024. Script switches to:
- `https://el7.repo.almalinux.org/centos/CentOS-Base.repo` (primary)
- `vault.centos.org/7.9.2009` (fallback)

### NIC Disappearing During Upgrade
**Cause:** `systemd-nspawn` v219 (CentOS 7) moves the host NIC into the
container namespace and never returns it (confirmed bug).

**Fix:** Replaces `/usr/bin/systemd-nspawn` with a wrapper that adds
`--network-none` to every call. Original binary is restored after upgrade.

### "Cannot set container mode for subscription-manager"
**Cause:** leapp calls `subscription-manager` inside the EL8 nspawn container,
which has its own copy installed as a dnf dependency.

**Fix:** Stubs the sub-mgr binary inside the EL8 installroot, writes
`manage_repos=0` to the installroot's `rhsm.conf`, and patches the leapp
actor to skip the check when `LEAPP_NO_RHSM=1`.

### "Leapp detected loaded kernel drivers not in RHEL 8"
**Cause:** Kernel modules loaded on CentOS 7 that don't exist in RHEL 8.

**Fix:** Proactively blacklists all 20+ known removed drivers in Step 4,
then parses the leapp report for any additional ones and blacklists those too.

### "Unable to install RHEL 8 userspace packages"
**Cause:** nspawn container can't reach repos (because of `--network-none`).

**Fix:** Pre-populates the EL8 installroot from the host (which has full
network), so the container never needs network access.

---

## All Options

| Flag | Description |
|------|-------------|
| `--target alma` | Upgrade to AlmaLinux 8 (default) |
| `--target rocky` | Upgrade to Rocky Linux 8 |
| `--backup-dev /dev/sdX` | Write disk image backup to block device |
| `--backup-dir /path` | Write compressed backup image to directory |
| `--backup-only` | Take backup then exit (no migration) |
| `--skip-backup` | Skip backup — NOT recommended |
| `--restore` | Interactive restore from previous backup |
| `--auto-yes`, `-y` | Skip confirmation prompts |
| `--post-upgrade` | Post-reboot validation |
| `--help` | Show usage |

---

## After the Upgrade

```bash
# Validate the upgrade
sudo ./centos7_to_el8_migrate.sh --post-upgrade

# Set Python 3 as default
alternatives --set python /usr/bin/python3

# Re-enable SELinux enforcing
sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
touch /.autorelabel && reboot

# Update all packages
dnf update -y

# Check for leftover CentOS 7 packages
rpm -qa | grep el7

# Clean up leapp artifacts
rm -fr /root/tmp_leapp_py3
dnf clean all
```

---

## Logs

All logs are written to `/var/log/el8-migration/`:

| File | Contents |
|------|----------|
| `migrate_TIMESTAMP.log` | Full script log |
| `backup_metadata_TIMESTAMP.txt` | Backup details and restore commands |
| `preupgrade_attemptN_TIMESTAMP.log` | leapp preupgrade output |
| `leapp-report_attemptN_TIMESTAMP.txt` | leapp report per attempt |
| `leapp-upgrade_TIMESTAMP.log` | leapp upgrade output |

---

## License

MIT
