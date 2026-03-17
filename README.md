# CentOS 7 to EL8 Migration Script

A fully functional bash script to migrate **CentOS 7** to **AlmaLinux 8** or **Rocky Linux 8** using the ELevate framework. 

## ⚙️ Configuration
Before execution, edit the following variables at the top of `centos7-el8-migrate.sh`:

| Variable | Description |
| :--- | :--- |
| `DISK_TO_BACKUP` | The physical disk device you want to image (e.g., `/dev/sda`). |
| `BACKUP_DIR` | The destination directory for your backup. **Crucial:** This should be a mount point for an external drive or network share to avoid filling up the OS disk. |
| `TARGET_OS` | Set to either `almalinux` or `rockylinux`. |

## ⚠️ Warning
This script performs an in-place OS upgrade. While it includes a `dd` backup option, always ensure you have off-site backups of your critical data. 

## Usage

1. **Clone & Prep:**
   ```bash
   git clone [https://github.com/yourusername/your-repo-name.git](https://github.com/yourusername/your-repo-name.git)
   cd your-repo-name
   chmod +x centos7-el8-migrate.sh
