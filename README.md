# Universal CentOS 7 to EL8 Migrator

A self-healing bash script to migrate CentOS 7 to **AlmaLinux 8** or **Rocky Linux 8** using the ELevate framework.

## ✨ Features
- **Working Archive Repos:** Automatically replaces dead CentOS 7 mirrors with `archive.kernel.org` to ensure package availability.
- **Bi-Modal Design:** Runs the migration on CentOS 7 and handles system cleanup on EL8.
- **Auto-Inhibitor Fix:** Resolves `pata_acpi`, `pam_pkcs11`, and `SSH` blocks automatically.
- **Smart Backup:** Auto-detects the root disk for `dd` imaging.

## 🚀 Usage

### Phase 1: The Migration
1. Clone and run:
   ```bash
   chmod +x centos7-el8-migrate.sh
   sudo ./centos7-el8-migrate.sh
