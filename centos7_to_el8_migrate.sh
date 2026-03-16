#!/usr/bin/env bash
# =============================================================================
# CentOS 7 → AlmaLinux / Rocky Linux 8 Migration Script
# Production Safe Version
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VERSION="1.0"
TARGET="alma"
AUTO_YES=false
LOG_DIR="/var/log/el8-migration"
LOG_FILE="$LOG_DIR/migrate.log"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

mkdir -p "$LOG_DIR"

log() {
    echo -e "$(date '+%F %T') | $*" | tee -a "$LOG_FILE"
}

die() {
    log "${RED}ERROR:${RST} $*"
    exit 1
}

confirm() {
    [[ "$AUTO_YES" == true ]] && return 0
    read -rp "$* [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# =============================================================================
# Check system
# =============================================================================

check_system() {

    log "${CYN}Checking system requirements...${RST}"

    [[ $EUID -eq 0 ]] || die "Run as root"

    grep -qi "centos.*7" /etc/centos-release || \
        die "This script requires CentOS 7"

    [[ "$(uname -m)" == "x86_64" ]] || \
        die "Only x86_64 supported"

    curl -s https://repo.almalinux.org >/dev/null || \
        die "Internet connectivity required"

    log "${GRN}System check passed${RST}"
}

# =============================================================================
# Fix EOL repositories
# =============================================================================

fix_repos() {

    log "Fixing CentOS 7 repositories..."

    curl -fsSL \
      -o /etc/yum.repos.d/CentOS-Base.repo \
      https://el7.repo.almalinux.org/centos/CentOS-Base.repo

    yum clean all
    yum makecache fast
}

# =============================================================================
# Update system
# =============================================================================

update_system() {

    log "Updating system..."

    yum upgrade -y

    if ! grep -q "7.9" /etc/centos-release; then
        log "${YEL}WARNING: System not fully upgraded to 7.9${RST}"
    fi
}

# =============================================================================
# Pre-upgrade fixes
# =============================================================================

prepare_upgrade() {

    log "Applying pre-upgrade fixes..."

    yum remove -y \
        centos-release-scl \
        python2-virtualenv \
        abrt*

    yum install -y yum-utils curl

    package-cleanup --oldkernels --count=1 -y || true
}

# =============================================================================
# Install elevate + leapp
# =============================================================================

install_elevate() {

    log "Installing ELevate packages..."

    yum install -y \
        https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm

    if [[ "$TARGET" == "alma" ]]; then
        yum install -y leapp-upgrade leapp-data-almalinux
    else
        yum install -y leapp-upgrade leapp-data-rocky
    fi
}

# =============================================================================
# Run leapp preupgrade
# =============================================================================

run_preupgrade() {

    log "Running leapp preupgrade..."

    LEAPP_NO_RHSM=1 leapp preupgrade --no-rhsm

    if grep -q "Risk Factor: high" /var/log/leapp/leapp-report.txt; then
        log "${RED}Upgrade blockers detected:${RST}"
        grep -A3 "Risk Factor: high" /var/log/leapp/leapp-report.txt
        die "Resolve blockers before continuing"
    fi

    log "${GRN}Preupgrade check passed${RST}"
}

# =============================================================================
# Run upgrade
# =============================================================================

run_upgrade() {

    echo
    echo -e "${RED}THIS IS THE POINT OF NO RETURN${RST}"
    echo

    confirm "Proceed with upgrade?" || die "Aborted"

    LEAPP_NO_RHSM=1 leapp upgrade --no-rhsm

    log "Upgrade initiated. System will reboot."

    reboot
}

# =============================================================================
# Post upgrade validation
# =============================================================================

post_upgrade() {

    log "Validating upgrade..."

    cat /etc/os-release
    uname -r

    if grep -qi almalinux /etc/os-release; then
        log "${GRN}System successfully upgraded to AlmaLinux 8${RST}"
    elif grep -qi rocky /etc/os-release; then
        log "${GRN}System successfully upgraded to Rocky Linux 8${RST}"
    else
        log "${YEL}OS verification uncertain${RST}"
    fi

}

# =============================================================================
# MAIN
# =============================================================================

main() {

    check_system

    confirm "Start migration?" || exit 0

    fix_repos
    update_system
    prepare_upgrade
    install_elevate
    run_preupgrade
    run_upgrade
}

main "$@"
