# CentOS 7 to EL8 Migration Script

A fully functional bash script to migrate **CentOS 7** to **AlmaLinux 8** or **Rocky Linux 8** using the ELevate framework. Includes built-in support for full disk image backups.

## ⚠️ Warning
This script performs an in-place OS upgrade. While it includes a backup option, you should **never** run this on production systems without testing in a staging environment first.

## Features
- **Disk Backup:** Optional bit-for-bit disk image creation using `dd` and `gzip`.
- **Automatic Repo Fix:** Handles CentOS 7 EOL repository redirects to `vault.centos.org`.
- **Inhibitor Fixes:** Automatically addresses common Leapp blockers (PAM modules, SSH root login).
- **Target Selection:** Choose between AlmaLinux or Rocky Linux.

## Prerequisites
- **Root access.**
- **Disk Space:** At least 5GB free on `/` and enough space on your backup destination for the compressed image.
- **Internet:** Required to download EL8 packages.

## Usage

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Suman99pro/centos7-el8-migrate.git
   cd centos7-el8-migrate
   chmod +x centos7-el8-migrate.sh
