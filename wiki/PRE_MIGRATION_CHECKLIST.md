# Pre-Migration Checklist

Use this checklist before running the live upgrade. Print it out or keep it open in a second terminal.

---

## ✅ Before You Start

### Access & Connectivity
- [ ] You have **out-of-band console access** (IPMI, iDRAC, KVM-over-IP, hypervisor console) — SSH will be unavailable during reboot
- [ ] At least **two separate SSH sessions** open (in case one drops)
- [ ] You know how to access the server if SSH fails post-upgrade
- [ ] You have the **root password** written down (not just SSH key access)
- [ ] A maintenance window is scheduled and stakeholders are notified

### System State
- [ ] No active user sessions or long-running jobs (`who`, `w`, `ps aux`)
- [ ] No running backups or cron jobs during the upgrade window
- [ ] Application traffic has been drained (if load-balanced) or service is in maintenance mode
- [ ] Pending OS updates have been applied: `yum update -y`
- [ ] System has been rebooted recently to confirm it boots cleanly and services start

### Analysis Run
- [ ] `--analyze-only` has been run and the report reviewed
- [ ] All **CRITICAL** risk items are resolved
- [ ] All **HIGH** risk items have been acknowledged and a rollback plan exists
- [ ] Third-party repo compatibility with EL8 has been verified
- [ ] SCL packages have been identified and a migration plan is ready
- [ ] Python 2 dependencies have been identified (Python 2 is removed in EL8)

### Disk Space
- [ ] `/` has ≥ 10 GB free
- [ ] `/boot` has ≥ 1 GB free
- [ ] Old kernels removed: `package-cleanup --oldkernels --count=1 -y`

---

## 💾 Backup Verification

- [ ] Block-device backup has been taken (`--backup-dev /dev/sdX`)
- [ ] Backup MD5 verification passed (the script confirms this)
- [ ] `backup_metadata_*.txt` is saved and the restore command is recorded
- [ ] **OR** cloud snapshot / LVM snapshot has been taken and verified
- [ ] You know how to boot into rescue mode and restore from backup

---

## 🔧 Application-Specific Checks

### Web Stack
- [ ] Apache/Nginx config backed up: `/var/log/el8-migration/config_backup_*/`
- [ ] PHP version noted — EL8 AppStream equivalent identified (7.4, 8.0, 8.1)
- [ ] SSL certificates noted — expiry dates, locations, renewal method
- [ ] Virtual host configs reviewed for mod_php vs php-fpm requirement

### Database
- [ ] MySQL/MariaDB data directory backed up separately (`mysqldump` or binary backup)
- [ ] MySQL/MariaDB version noted — EL8-compatible version confirmed in repo
- [ ] `mysql_upgrade` or `mariadb-upgrade` will be run post-upgrade
- [ ] Database charset and collation noted (utf8 → utf8mb4 changes in MariaDB 10.4+)
- [ ] PostgreSQL data backed up (`pg_dumpall`)

### Application
- [ ] Application config files backed up
- [ ] Application uses EL8-compatible dependencies (no Python 2, no SCL)
- [ ] Application startup verified in staging on EL8 (if available)

### Monitoring & Logging
- [ ] Monitoring agent (Zabbix, Nagios, Datadog, etc.) EL8 package verified
- [ ] Log shipping agent (Filebeat, Fluentd, etc.) EL8 package verified
- [ ] Alerting suppressed during maintenance window

### Security
- [ ] fail2ban / IDS EL8 package verified
- [ ] Firewall rules documented (`firewall-cmd --list-all`, or `iptables-save`)
- [ ] SELinux policy noted — relabelling may be required post-upgrade

---

## 🚀 During Upgrade

- [ ] Console access active
- [ ] `leapp preupgrade` run — **zero inhibitors**
- [ ] `leapp-report.txt` reviewed: `/var/log/leapp/leapp-report.txt`
- [ ] leapp answers populated for any required prompts
- [ ] **Final backup taken** immediately before running `leapp upgrade`

---

## ✅ Post-Upgrade Validation

Run:
```bash
sudo ./centos7_to_el8_migrate.sh --post-upgrade
```

Then manually verify:
- [ ] OS version confirmed: `cat /etc/almalinux-release` or `/etc/rocky-release`
- [ ] Kernel version confirmed: `uname -r`
- [ ] `systemctl --failed` shows no failed units
- [ ] SSH accessible from external network
- [ ] Application endpoints responding (HTTP 200, DB connections)
- [ ] Logs not showing new errors: `journalctl -p err -n 50`
- [ ] Monitoring agent reporting correctly
- [ ] `.rpmsave`/`.rpmnew` files reviewed and resolved
- [ ] EPEL 8 installed: `dnf install -y epel-release`
- [ ] Security updates applied: `dnf update --security -y`
- [ ] SELinux relabelling done if needed: `touch /.autorelabel && reboot`
- [ ] Crypto policy reviewed: `update-crypto-policies --show`

---

## 📞 Emergency Rollback

If anything is wrong post-upgrade and cannot be quickly resolved:

```bash
# Boot from live USB / rescue environment, then:
dd if=/dev/BACKUP_DEVICE of=/dev/SOURCE_DISK bs=4M conv=noerror,sync status=progress

# Fix bootloader after restore:
grub2-install /dev/sda
grub2-mkconfig -o /boot/grub2/grub.cfg

# Reboot
reboot
```

The exact command is in: `/var/log/el8-migration/backup_metadata_TIMESTAMP.txt`

---

*Return to [README](../README.md) · [Troubleshooting](TROUBLESHOOTING.md)*
