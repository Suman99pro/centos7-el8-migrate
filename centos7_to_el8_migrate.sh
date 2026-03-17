#!/bin/bash

# ==============================================================================
# Script Name: centos7-el8-migrate.sh
# Version: 2.1 (Universal Archive Edition)
# Description: CentOS 7 -> EL8 Migration + Post-Upgrade Cleanup
# ==============================================================================

set -e

# --- Configuration ---
LOG_FILE="/var/log/migration_$(date +%F).log"
TARGET_OS="almalinux" # Options: almalinux, rockylinux

# UI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

log() { echo -e "${GREEN}[$(date +'%F %T')] $1${NC}" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}" | tee -a "$LOG_FILE"; }
error_exit() { echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"; exit 1; }

if [[ $EUID -ne 0 ]]; then error_exit "This script must be run as root."; fi

# --- DETECTION LOGIC: Are we on EL7 or EL8? ---
OS_VER=$(rpm -E %{rhel})

if [[ "$OS_VER" == "8" ]]; then
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${GREEN}  DETECTED ALMALINUX / ROCKY 8 - POST-UPGRADE MODE     ${NC}"
    echo -e "${BLUE}========================================================${NC}"
    
    read -p "Do you want to perform post-upgrade cleanup (remove el7 pkgs, set Python)? (y/n): " do_cleanup
    if [[ $do_cleanup == "y" ]]; then
        log "Setting Python 3 as default..."
        alternatives --set python /usr/bin/python3 || warn "Could not set python3 alternatives."
        
        log "Removing leftover EL7 packages..."
        EL7_PKGS=$(rpm -qa | grep el7 | grep -v "gpg-pubkey" || true)
        if [ -n "$EL7_PKGS" ]; then
            yum remove -y $EL7_PKGS || warn "Some EL7 packages remained."
        fi
        
        log "Cleaning up DNF metadata..."
        dnf clean all && rm -rf /var/cache/dnf
        log "SUCCESS: Cleanup complete."
    fi
    exit 0
fi

# --- MIGRATION LOGIC (For CentOS 7) ---
echo "--------------------------------------------------------"
echo " CentOS 7 to EL8 Migration Tool (Universal Archive)    "
echo "--------------------------------------------------------"

# 1. Kernel and Root Disk Detection
DETECTED_ROOT_DISK=$(lsblk -no pkname $(findmnt -nvo SOURCE /))
CURRENT_KERN=$(uname -r)
LATEST_KERN=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)

if [[ "$CURRENT_KERN" != "$LATEST_KERN" ]]; then
    warn "Kernel mismatch! Running: $CURRENT_KERN | Latest: $LATEST_KERN"
    read -p "Reboot required to load new kernel. Reboot now? (y/n): " kern_reboot
    [[ $kern_reboot == "y" ]] && reboot || error_exit "Please reboot and run script again."
fi

# 2. Universal Backup
read -p "Create full disk image backup of /dev/$DETECTED_ROOT_DISK? (y/n): " do_backup
if [[ $do_backup == "y" ]]; then
    read -p "Enter full path for backup (e.g. /mnt/external/backup.img.gz): " BACKUP_PATH
    log "Imaging /dev/$DETECTED_ROOT_DISK to $BACKUP_PATH..."
    dd if="/dev/$DETECTED_ROOT_DISK" conv=sync,noerror bs=64K status=progress | gzip -c > "$BACKUP_PATH" || warn "Backup incomplete."
fi

# 3. Fixing EOL Repos using Archive.kernel.org (Working Version)
log "Updating CentOS 7 Repos to Kernel Archive..."
mkdir -p /etc/yum.repos.d/old_repos
mv /etc/yum.repos.d/CentOS-* /etc/yum.repos.d/old_repos/ || true

cat <<EOF > /etc/yum.repos.d/CentOS-Archive.repo
[base]
name=CentOS-7 - Base
baseurl=http://archive.kernel.org/centos-vault/7.9.2009/os/\$basearch/
enabled=1
gpgcheck=0

[updates]
name=CentOS-7 - Updates
baseurl=http://archive.kernel.org/centos-vault/7.9.2009/updates/\$basearch/
enabled=1
gpgcheck=0

[extras]
name=CentOS-7 - Extras
baseurl=http://archive.kernel.org/centos-vault/7.9.2009/extras/\$basearch/
enabled=1
gpgcheck=0
EOF

yum clean all && yum makecache && yum update -y

# 4. Tool Installation
log "Installing ELevate for $TARGET_OS..."
yum install -y http://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm
[[ "$TARGET_OS" == "almalinux" ]] && yum install -y leapp-upgrade leapp-data-almalinux || yum install -y leapp-upgrade leapp-data-rocky

# 5. Resolving Inhibitors
log "Silencing inhibitors..."
modprobe -r pata_acpi || true
leapp answer --section remove_pam_pkcs11_module_check.confirm=True || true
grep -q "PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

# 6. Execution
log "Running Pre-upgrade check..."
set +e
leapp preupgrade
PRE_STATUS=$?
set -e

if [ $PRE_STATUS -eq 0 ]; then
    log "Passed! Starting OS Upgrade..."
    leapp upgrade
    log "Rebooting in 10s to finalize."
    sleep 10 && reboot
else
    error_exit "Migration inhibited. Check /var/log/leapp/leapp-report.txt"
fi
