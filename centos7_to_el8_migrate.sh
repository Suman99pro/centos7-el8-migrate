#!/bin/bash

# ==============================================================================
# Script Name: centos7-el8-migrate.sh
# Author: [Your Name/GitHub Handle]
# Description: Automates CentOS 7 to AlmaLinux 8 or Rocky Linux 8 migration.
# ==============================================================================

set -e

# --- Configuration ---
LOG_FILE="/var/log/migration_$(date +%F).log"
BACKUP_DIR="/mnt/backup_migration" # MUST be a separate physical drive/mount
DISK_TO_BACKUP="/dev/sda"          # Change to your root disk (e.g., /dev/nvme0n1)
TARGET_OS="almalinux"              # Options: almalinux, rockylinux

# UI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' 

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error_exit() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

if [[ $EUID -ne 0 ]]; then
   error_exit "This script must be run as root."
fi

echo "--------------------------------------------------------"
echo " CentOS 7 to EL8 Migration Tool (ELevate)              "
echo "--------------------------------------------------------"

# 1. Backup Logic
read -p "Do you want to create a full disk image backup before proceeding? (y/n): " do_backup
if [[ $do_backup == "y" ]]; then
    if ! mountpoint -q "$BACKUP_DIR"; then
        log "Warning: $BACKUP_DIR does not appear to be a separate mount point."
        read -p "Are you sure you want to save the backup here? (y/n): " confirm_mount
        [[ $confirm_mount != "y" ]] && error_exit "Aborted to prevent disk space exhaustion."
    fi

    mkdir -p "$BACKUP_DIR"
    log "Starting full disk backup of $DISK_TO_BACKUP to $BACKUP_DIR..."
    dd if="$DISK_TO_BACKUP" conv=sync,noerror bs=64K status=progress | gzip -c > "$BACKUP_DIR/centos7_backup_$(date +%F).img.gz" || error_exit "Backup failed!"
    log "Backup completed: $BACKUP_DIR/centos7_backup_$(date +%F).img.gz"
fi

# 2. Preparation & EOL Repo Fix
log "Updating CentOS 7 and fixing EOL repositories..."
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

yum update -y || error_exit "Initial system update failed."

# 3. Install Migration Tools
log "Installing ELevate and Leapp for $TARGET_OS..."
yum install -y http://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm

if [[ "$TARGET_OS" == "almalinux" ]]; then
    yum install -y leapp-upgrade leapp-data-almalinux
else
    yum install -y leapp-upgrade leapp-data-rocky
fi

# 4. Pre-upgrade
log "Running Leapp pre-upgrade check..."
set +e 
leapp preupgrade
set -e

log "Applying automated fixes for known inhibitors..."
rmmod pata_acpi || true
echo PermitRootLogin yes >> /etc/ssh/sshd_config
leapp answer --section remove_pam_pkcs11_module_check.confirm=True

# 5. Final Execution
echo -e "${RED}Final check: Review /var/log/leapp/leapp-report.txt before proceeding.${NC}"
read -p "Proceed with the actual OS upgrade? (y/n): " run_upgrade
if [[ $run_upgrade == "y" ]]; then
    log "Starting Leapp upgrade. This will take time."
    leapp upgrade || error_exit "Leapp upgrade process failed."
    log "Upgrade staged. Rebooting to finish the process..."
    sleep 5
    reboot
else
    log "Upgrade halted by user."
fi
