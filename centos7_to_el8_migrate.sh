#!/bin/bash

# ==============================================================================
# Script Name: CentOS 7 to EL8 Migration (AlmaLinux/Rocky)
# Author: [Your Name/GitHub Handle]
# Description: Automates CentOS 7 to AlmaLinux 8 or Rocky Linux 8 migration.
# ==============================================================================

set -e

# Configuration
LOG_FILE="/var/log/migration_$(date +%F).log"
BACKUP_DIR="/mnt/backup_migration" # Change this to a mounted external drive
DISK_TO_BACKUP="/dev/sda"          # Change to your root disk (e.g., /dev/nvme0n1)
TARGET_OS="almalinux"              # Options: almalinux, rockylinux

# UI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error_exit() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

# Check for Root
if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root."
fi

echo "--------------------------------------------------------"
echo " CentOS 7 to AlmaLinux 8 / Rocky Linux 8 Migration Tool "
echo "--------------------------------------------------------"

# 1. Ask for Backup
read -p "Do you want to create a full disk image backup before proceeding? (y/n): " do_backup
if [[ $do_backup == "y" ]]; then
    mkdir -p "$BACKUP_DIR"
    log "Starting full disk backup of $DISK_TO_BACKUP to $BACKUP_DIR..."
    log "This may take a long time depending on disk size."
    # Using dd with status=progress for visibility
    dd if="$DISK_TO_BACKUP" conv=sync,noerror bs=64K status=progress | gzip -c > "$BACKUP_DIR/centos7_backup_$(date +%F).img.gz" || error_exit "Backup failed!"
    log "Backup completed successfully."
fi

# 2. Prepare CentOS 7
log "Updating CentOS 7 to the latest version..."
# Fix for CentOS 7 EOL repos (switching to vault if needed)
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

yum update -y || error_exit "Yum update failed."
log "System updated. Please reboot manually if a new kernel was installed, then run this script again."

# 3. Install ELevate and Leapp
log "Installing ELevate and Leapp..."
yum install -y http://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm

if [[ "$TARGET_OS" == "almalinux" ]]; then
    yum install -y leapp-upgrade leapp-data-almalinux || error_exit "Failed to install AlmaLinux data."
else
    yum install -y leapp-upgrade leapp-data-rocky || error_exit "Failed to install Rocky Linux data."
fi

# 4. Pre-upgrade Check
log "Running Leapp pre-upgrade check..."
set +e # Don't exit on pre-upgrade failure as inhibitors are expected
leapp preupgrade

log "Review /var/log/leapp/leapp-report.txt for inhibitors."
log "Applying common fixes..."

# Fix common inhibitors
rmmod pata_acpi || true
echo PermitRootLogin yes >> /etc/ssh/sshd_config
leapp answer --section remove_pam_pkcs11_module_check.confirm=True

# 5. Final Upgrade
read -p "Ready to start the actual upgrade? (y/n): " run_upgrade
if [[ $run_upgrade == "y" ]]; then
    log "Starting Leapp upgrade. DO NOT INTERRUPT."
    leapp upgrade || error_exit "Upgrade command failed."
    log "Upgrade staged. Rebooting in 10 seconds..."
    sleep 10
    reboot
else
    log "Upgrade cancelled by user."
fi
