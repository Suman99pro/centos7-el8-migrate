# Universal CentOS 7 to EL8 Migrator

A "one-and-done" self-healing script to migrate from CentOS 7 to **AlmaLinux 8** or **Rocky Linux 8**. This script handles the complex migration logic, fixes broken repositories, and performs post-upgrade cleanup in a single file.

## 🌟 How it Works
This script is bi-modal. It detects your current OS version and adjusts its behavior:
1.  **Phase 1 (CentOS 7):** Acts as a migration orchestrator. It repairs EOL repositories using `archive.kernel.org`, resolves inhibitors, and initiates the ELevate process.
2.  **Phase 2 (EL8):** Acts as a cleanup utility. After the reboot, running the same script optimizes your new environment by removing legacy packages and setting system defaults.

---

## 🚀 Execution Guide

### Phase 1: Migration (Run on CentOS 7)
Prepare your system and start the migration process:

```bash
git clone https://github.com/Suman99pro/centos7-el8-migrate.git
cd centos7-el8-migrate
chmod +x centos7-el8-migrate.sh
sudo ./centos7-el8-migrate.sh
