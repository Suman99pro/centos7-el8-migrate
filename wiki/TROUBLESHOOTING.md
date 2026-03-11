# Troubleshooting Guide

This page covers the most common errors and how to resolve them.

---

## Table of Contents

- [Pre-Upgrade Errors](#pre-upgrade-errors)
- [leapp Inhibitors](#leapp-inhibitors)
- [Backup Errors](#backup-errors)
- [Upgrade Failures](#upgrade-failures)
- [Post-Upgrade Issues](#post-upgrade-issues)
- [Service-Specific Issues](#service-specific-issues)

---

## Pre-Upgrade Errors

### `ERROR: This script must be run as root`

**Cause:** Script was run without root privileges.

**Fix:**
```bash
sudo ./centos7_to_el8_migrate.sh --analyze-only
# or
su -c "./centos7_to_el8_migrate.sh --analyze-only"
```

---

### `ERROR: Only CentOS 7.x is supported`

**Cause:** The script detected a non-CentOS 7 OS (e.g., CentOS 8, CentOS Stream, RHEL).

**Fix:** This script is for CentOS Linux 7.x only. CentOS Stream and RHEL have separate upgrade paths.

---

### `CRITICAL: /: Only XG available. ELevate requires ≥10G`

**Cause:** Insufficient free space on the root filesystem.

**Fix:**
```bash
# Find and remove large files
du -sh /var/log/* | sort -rh | head -20
du -sh /var/cache/* | sort -rh | head -20

# Remove old kernels
package-cleanup --oldkernels --count=1 -y

# Clean yum cache
yum clean all
rm -rf /var/cache/yum

# Check what's using space
ncdu /   # install with: yum install ncdu
```

---

### `CRITICAL: /boot: Only XG available`

**Cause:** `/boot` is full, usually due to old kernel images.

**Fix:**
```bash
# List installed kernels
rpm -q kernel

# Remove all but the latest
package-cleanup --oldkernels --count=1 -y

# Verify space freed
df -h /boot
```

---

### `Missing tools: pv`

**Cause:** `pv` is not installed (used for progress bar during backup).

**Fix:** This is non-critical — the script falls back to `dd status=progress`. To install:
```bash
yum install -y epel-release && yum install -y pv
```

---

## leapp Inhibitors

The leapp pre-upgrade check (`leapp preupgrade`) may flag **inhibitors** — issues that will prevent the upgrade from completing. These must be resolved.

Full report: `/var/log/leapp/leapp-report.txt`

---

### Inhibitor: `Detected loaded kernel drivers which have been removed in RHEL 8`

**Cause:** A kernel module loaded on the system is not present in the EL8 kernel.

**Fix:**
```bash
# List the problematic module(s) from the leapp report, then:
modprobe -r <module_name>     # unload it
echo "blacklist <module_name>" >> /etc/modprobe.d/blacklist.conf
```

---

### Inhibitor: `Missing required answers in the answer file`

**Cause:** leapp needs explicit confirmation for certain upgrade actions.

**Fix:**
```bash
leapp answer --section remove_pam_pkcs11_module_check.confirm=True
leapp answer --section authselect_check.confirm=True
# Then re-run:
leapp preupgrade
```

---

### Inhibitor: `Upgrade requires the root file system to be ext4 or xfs`

**Cause:** Root filesystem uses an unsupported filesystem type (e.g., ext3, btrfs).

**Fix:** This is a hard blocker. Convert the filesystem or perform a fresh install of EL8 instead of an in-place upgrade.

---

### Inhibitor: `Multiple ${OS_NAME} kernel versions found`

**Cause:** More than one kernel version is installed.

**Fix:**
```bash
package-cleanup --oldkernels --count=1 -y
reboot   # Boot into the latest kernel first
```

---

### Inhibitor: `A YUM/DNF repository is not compatible`

**Cause:** A third-party repo does not have an EL8-compatible baseurl.

**Fix:**
```bash
# Disable the problematic repo
yum-config-manager --disable <repo-name>
# Then re-run leapp preupgrade
```

---

## Backup Errors

### `ERROR: Backup device '/dev/sdX' is not a valid block device`

**Cause:** The device path specified with `--backup-dev` does not exist or is not a block device.

**Fix:**
```bash
# List block devices
lsblk

# Verify the device
ls -la /dev/sdb
```

---

### `ERROR: Backup device is smaller than source disk`

**Cause:** The backup destination is smaller than the source disk.

**Fix:** Use a larger backup device. The destination must be ≥ source size.

```bash
lsblk -o NAME,SIZE   # Compare sizes
```

---

### `ERROR: MD5 MISMATCH — backup may be corrupt`

**Cause:** The first 512 MB of backup does not match the source — hardware error, interrupted write, or failing disk.

**Fix:**
1. Run the backup again
2. If persistent, try a different backup device
3. Check the source disk for errors: `badblocks -v /dev/sda`

---

## Upgrade Failures

### System Stuck During Upgrade Reboot

**Symptom:** System rebooted into the upgrade initramfs but has not come back after >90 minutes.

**Action:**
1. Access via console (IPMI/iDRAC/KVM-over-IP)
2. Check the upgrade log: `/var/log/leapp/leapp-upgrade.log` (may be accessible from rescue mode)
3. If unrecoverable, restore from backup:
   ```bash
   # Boot from live USB, then:
   dd if=/dev/sdb of=/dev/sda bs=4M conv=noerror,sync status=progress
   grub2-install /dev/sda
   grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

---

### `leapp upgrade` Exits with Error Before Reboot

**Cause:** A pre-upgrade check or package transaction failed.

**Fix:**
```bash
# Review the leapp log
cat /var/log/leapp/leapp-upgrade.log | grep -i "error\|fail"

# Re-run preupgrade to refresh checks
leapp preupgrade

# Check for RPM database corruption
rpm --rebuilddb
```

---

### Package Transaction Conflicts During Upgrade

**Cause:** Third-party packages conflict with the EL8 package set.

**Fix:**
```bash
# Review leapp report for package conflicts
grep -i "conflict\|obsolete" /var/log/leapp/leapp-report.txt

# Remove the conflicting package:
yum remove <package-name>

# Re-run preupgrade
leapp preupgrade
```

---

## Post-Upgrade Issues

### SSH Won't Connect After Upgrade

**Cause:** sshd configuration incompatibility or service failed to start.

**Fix (via console):**
```bash
systemctl status sshd
journalctl -u sshd -n 50

# Common fix — crypto policy changed:
update-crypto-policies --set DEFAULT

# Restart sshd
systemctl restart sshd

# Check config syntax
sshd -t
```

---

### Network Interface Not Coming Up

**Cause:** Network interface name changed (e.g., `eth0` → `ens3`) or NetworkManager config not migrated.

**Fix:**
```bash
ip link show   # See actual interface names

# Check NetworkManager status
systemctl status NetworkManager

# List connections
nmcli connection show

# If ifcfg scripts don't match new interface names:
nmcli connection migrate   # Migrate ifcfg to keyfile format
```

---

### Services Failing Post-Upgrade

**Cause:** Unit files changed, config incompatibilities, or package not migrated.

**Fix:**
```bash
# List all failed units
systemctl --failed

# Check specific service
systemctl status <service-name>
journalctl -u <service-name> -n 100

# Reload daemon and restart
systemctl daemon-reload
systemctl restart <service-name>
```

---

### `.rpmsave` / `.rpmnew` Config Conflicts

**Cause:** RPM saved the old config as `.rpmsave` when it could not safely merge with the new package default.

**Fix:**
```bash
# Find all conflicts
find /etc -name "*.rpmsave" -o -name "*.rpmnew" 2>/dev/null

# For each file, diff and merge:
diff /etc/httpd/conf/httpd.conf.rpmsave /etc/httpd/conf/httpd.conf
# Apply your customisations from .rpmsave into the new file
```

---

## Service-Specific Issues

### Apache HTTPD / PHP

```bash
# If mod_php was used on EL7, EL8 defaults to php-fpm:
dnf install -y php php-fpm
systemctl enable --now php-fpm

# Switch Apache to event MPM (or keep prefork for mod_php if needed):
# /etc/httpd/conf.modules.d/00-mpm.conf
systemctl restart httpd
```

### MySQL / MariaDB

```bash
# After upgrade, run the upgrade script:
mysql_upgrade -u root -p

# Or for MariaDB:
mariadb-upgrade -u root -p
```

### Docker / Podman

```bash
# Re-add Docker CE repo for EL8:
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker

# Or switch to Podman (built into EL8):
dnf install -y podman
```

---

*If your issue is not listed here, please [open a GitHub Issue](../../issues) with your log output.*
