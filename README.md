# Universal CentOS 7 to EL8 Migrator

A "one-and-done" script to migrate from CentOS 7 to **AlmaLinux 8** or **Rocky Linux 8**. This script handles the complex migration logic and the necessary post-upgrade cleanup in a single file.

## 🌟 How it Works
This script is designed to be run twice:
1.  **Phase 1 (CentOS 7):** Acts as a migration orchestrator. It repairs EOL repositories, resolves system inhibitors, and initiates the ELevate/Leapp process.
2.  **Phase 2 (EL8):** Acts as a cleanup utility. After the reboot, running the same script will detect the new OS and offer to optimize the system.

---

## 🚀 Usage Instructions

### 1. Preparation & Migration
Clone the repository and execute the script on your CentOS 7 machine:

```bash
git clone https://github.com/Suman99pro/centos7-el8-migrate.git
cd centos7-el8-migrate
chmod +x centos7-el8-migrate.sh
sudo ./centos7-el8-migrate.sh
