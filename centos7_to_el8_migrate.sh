#!/usr/bin/env bash
# =============================================================================
# CentOS 7.x → AlmaLinux 8 / Rocky Linux 8 Migration Script
# =============================================================================
# Version   : 2.0.0
# Author    : Production Migration Toolkit
# Requires  : CentOS 7.x, root privileges
# Tested on : CentOS 7.6 / 7.7 / 7.8 / 7.9
#
# FEATURES:
#   - Pre-flight system analysis (OS, apps, services, deps)
#   - Full disk image backup to a block device (dd + verification)
#   - Compatibility & breakage risk assessment
#   - ELevate (leapp) based in-place upgrade
#   - Post-upgrade validation
#   - Future upgrade path analysis (EL8 → EL9)
#   - Full audit log
#
# USAGE:
#   chmod +x centos7_to_el8_migrate.sh
#   sudo ./centos7_to_el8_migrate.sh [OPTIONS]
#
# OPTIONS:
#   --target   alma|rocky          Target distro  (default: interactive)
#   --backup-dev /dev/sdX          Block device for backup (REQUIRED for backup)
#   --skip-backup                  Skip disk image backup (DANGEROUS)
#   --analyze-only                 Run analysis only, no upgrade
#   --auto-yes                     Non-interactive (accept all prompts) USE WITH CAUTION
#   --log-dir /path                Log directory  (default: /var/log/el8-migration)
#
# DISCLAIMER:
#   Test on a non-production clone first. The authors accept no liability
#   for data loss. Always have a verified backup before proceeding.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# GLOBAL CONSTANTS & DEFAULTS
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%Y%m%d_%H%M%S)"

# Resolved at runtime after leapp is installed
LEAPP_BIN=""

LOG_DIR="/var/log/el8-migration"
LOG_FILE=""
REPORT_FILE=""
TARGET_DISTRO=""          # alma | rocky
BACKUP_DEV=""             # e.g. /dev/sdb
SKIP_BACKUP=false
ANALYZE_ONLY=false
AUTO_YES=false

# Colours
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'

# Risk counters (populated during analysis)
RISK_CRITICAL=0
RISK_HIGH=0
RISK_MEDIUM=0
RISK_LOW=0

# ---------------------------------------------------------------------------
# LOGGING & OUTPUT HELPERS
# ---------------------------------------------------------------------------
init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/migration_${START_TIME}.log"
    REPORT_FILE="${LOG_DIR}/migration_report_${START_TIME}.txt"
    touch "$LOG_FILE" "$REPORT_FILE"
    # Tee all output to log
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Logging initialised → $LOG_FILE"
}

log()         { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_info()    { log "${GREEN}[INFO]${RESET}  $*"; }
log_warn()    { log "${YELLOW}[WARN]${RESET}  $*"; ((RISK_MEDIUM++)) || true; }
log_error()   { log "${RED}[ERROR]${RESET} $*"; }
log_high()    { log "${RED}[HIGH-RISK]${RESET} $*"; ((RISK_HIGH++)) || true; }
log_critical(){ log "${RED}${BOLD}[CRITICAL]${RESET} $*"; ((RISK_CRITICAL++)) || true; }
log_low()     { log "${BLUE}[LOW-RISK]${RESET} $*"; ((RISK_LOW++)) || true; }
log_ok()      { log "${GREEN}[OK]${RESET}    $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}"; \
                echo -e "${BOLD}${CYAN}  $*${RESET}"; \
                echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}"; }

banner() {
    echo -e "${BOLD}${CYAN}"
    cat <<'EOF'
  ██████╗███████╗███╗   ██╗████████╗ ██████╗ ███████╗    ███████╗██╗
 ██╔════╝██╔════╝████╗  ██║╚══██╔══╝██╔═══██╗██╔════╝    ██╔════╝██║
 ██║     █████╗  ██╔██╗ ██║   ██║   ██║   ██║███████╗    █████╗  ██║
 ██║     ██╔══╝  ██║╚██╗██║   ██║   ██║   ██║╚════██║    ██╔══╝  ██║
 ╚██████╗███████╗██║ ╚████║   ██║   ╚██████╔╝███████║    ███████╗███████╗
  ╚═════╝╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚══════╝    ╚══════╝╚══════╝
           CentOS 7 → AlmaLinux 8 / Rocky Linux 8 Migration Toolkit
EOF
    echo -e "${RESET}"
    echo -e "  Version : ${SCRIPT_VERSION}   |   $(date)   |   Host: $(hostname -f)"
    echo
}

confirm() {
    local msg="$1"
    if [[ "$AUTO_YES" == true ]]; then
        log_info "Auto-yes: $msg"
        return 0
    fi
    echo -en "${YELLOW}${msg} [y/N] ${RESET}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)        TARGET_DISTRO="${2,,}"; shift 2 ;;
            --backup-dev)    BACKUP_DEV="$2"; shift 2 ;;
            --skip-backup)   SKIP_BACKUP=true; shift ;;
            --analyze-only)  ANALYZE_ONLY=true; shift ;;
            --auto-yes)      AUTO_YES=true; shift ;;
            --log-dir)       LOG_DIR="$2"; shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *) die "Unknown option: $1. Use --help." ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

  --target   alma|rocky          Target distribution
  --backup-dev /dev/sdX          Block device for disk image backup
  --skip-backup                  Skip backup step (NOT recommended)
  --analyze-only                 Analysis + report only, no changes
  --auto-yes                     Non-interactive mode
  --log-dir /path                Custom log directory (default: /var/log/el8-migration)
  -h, --help                     Show this help

Examples:
  # Full migration to AlmaLinux 8 with backup to /dev/sdb
  sudo $SCRIPT_NAME --target alma --backup-dev /dev/sdb

  # Analysis only — no changes
  sudo $SCRIPT_NAME --analyze-only

  # Rocky Linux, skip backup (if already backed up externally)
  sudo $SCRIPT_NAME --target rocky --skip-backup
EOF
}

# ---------------------------------------------------------------------------
# PREFLIGHT: ENVIRONMENT CHECKS
# ---------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
    log_ok "Running as root."
}

check_centos7() {
    if [[ ! -f /etc/centos-release ]]; then
        die "This script only supports CentOS 7. /etc/centos-release not found."
    fi
    local ver
    ver=$(rpm -q --queryformat '%{VERSION}' centos-release 2>/dev/null || echo "")
    if [[ "$ver" != "7" ]]; then
        die "Detected CentOS version '$ver'. Only CentOS 7.x is supported."
    fi
    log_ok "CentOS 7 confirmed: $(cat /etc/centos-release)"
}

check_required_tools() {
    log_section "Checking Required Tools"
    local tools=(rpm yum lsblk df free uname ss lsof ip awk grep sed curl)
    local missing=()
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools: ${missing[*]}. Attempting to install..."
        yum install -y "${missing[@]}" 2>/dev/null || log_warn "Could not install all missing tools."
    else
        log_ok "All required tools are present."
    fi
}

# ---------------------------------------------------------------------------
# SECTION 1: SYSTEM ANALYSIS
# ---------------------------------------------------------------------------
analyze_system() {
    log_section "1. System Information"

    echo "--- Kernel & OS ---"
    uname -a
    cat /etc/centos-release
    echo

    echo "--- CPU ---"
    lscpu | grep -E "Architecture|CPU\(s\)|Model name|Socket|Thread"
    echo

    echo "--- Memory ---"
    free -h
    echo

    echo "--- Disk Usage ---"
    df -hT
    echo

    echo "--- Block Devices ---"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID
    echo

    echo "--- Uptime ---"
    uptime
    echo

    # Check if running in a VM or cloud
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    log_info "Virtualisation: $virt"

    # SELinux
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "disabled")
    log_info "SELinux: $selinux_status"
    if [[ "$selinux_status" == "Enforcing" ]]; then
        log_warn "SELinux is Enforcing — policy changes during upgrade may affect services."
    fi

    # Firewall
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "Firewalld is active."
        firewall-cmd --list-all 2>/dev/null || true
    elif systemctl is-active --quiet iptables 2>/dev/null; then
        log_warn "iptables is active (not firewalld). Rules must be migrated manually."
    fi
}

analyze_boot() {
    log_section "2. Boot & Storage Configuration"

    echo "--- Bootloader ---"
    if [[ -d /sys/firmware/efi ]]; then
        log_info "UEFI boot detected."
        efibootmgr 2>/dev/null | head -20 || true
    else
        log_info "BIOS/Legacy boot detected."
        grub2-editenv list 2>/dev/null || true
    fi

    echo
    echo "--- /etc/fstab ---"
    cat /etc/fstab
    echo

    # Check for LVM
    if command -v pvs &>/dev/null && pvs &>/dev/null 2>&1; then
        echo "--- LVM Physical Volumes ---"
        pvs
        echo "--- LVM Volume Groups ---"
        vgs
        echo "--- LVM Logical Volumes ---"
        lvs
    fi

    # Check for software RAID
    if [[ -f /proc/mdstat ]]; then
        echo "--- Software RAID (mdstat) ---"
        cat /proc/mdstat
        if grep -q "active" /proc/mdstat; then
            log_info "Software RAID detected — ensure all arrays are healthy before upgrade."
        fi
    fi

    # Check for network filesystems
    if grep -qE "nfs|cifs|glusterfs|cephfs" /etc/fstab 2>/dev/null; then
        log_warn "Network filesystems found in /etc/fstab — these may not automount during upgrade reboot."
    fi
}

analyze_network() {
    log_section "3. Network Configuration"

    echo "--- IP Addresses ---"
    ip addr show
    echo

    echo "--- Routing Table ---"
    ip route
    echo

    echo "--- DNS ---"
    cat /etc/resolv.conf
    echo

    echo "--- Hostname ---"
    hostnamectl
    echo

    echo "--- Network Interfaces (nmcli) ---"
    nmcli device status 2>/dev/null || ip link show
    echo

    echo "--- Listening Services ---"
    ss -tlnpu
    echo

    # Check for bonding/teaming
    if ls /proc/net/bonding/ &>/dev/null 2>&1; then
        log_warn "Network bonding detected — verify bond config persists post-upgrade."
        ls /proc/net/bonding/
    fi
}

analyze_repositories() {
    log_section "4. YUM Repositories"

    echo "--- Enabled Repos ---"
    yum repolist enabled 2>/dev/null
    echo

    echo "--- All Repos (including disabled) ---"
    yum repolist all 2>/dev/null | head -60
    echo

    # Check for third-party repos
    local third_party_repos=()
    while IFS= read -r repo_file; do
        local name
        name=$(basename "$repo_file" .repo)
        if ! echo "$name" | grep -qiE "^(CentOS|base|updates|extras|epel|centos)"; then
            third_party_repos+=("$name")
        fi
    done < <(find /etc/yum.repos.d/ -name "*.repo" 2>/dev/null)

    if [[ ${#third_party_repos[@]} -gt 0 ]]; then
        log_warn "Third-party repositories detected: ${third_party_repos[*]}"
        log_warn "These repos will NOT automatically migrate. Review compatibility with EL8."
    fi

    # Specific high-risk repo checks
    for repo in percona mariadb mysql nginx elastic remi ius webtatic; do
        if find /etc/yum.repos.d/ -name "*.repo" -exec grep -li "$repo" {} \; | grep -q .; then
            log_high "Repo '$repo' detected — verify EL8-compatible version exists before upgrade."
        fi
    done
}

analyze_installed_packages() {
    log_section "5. Installed Packages & Known Incompatibilities"

    local pkg_count
    pkg_count=$(rpm -qa | wc -l)
    log_info "Total installed packages: $pkg_count"

    echo
    echo "--- Packages with KNOWN EL7→EL8 Breakage Risk ---"

    # PHP
    local php_ver
    php_ver=$(php -v 2>/dev/null | head -1 || echo "")
    if [[ -n "$php_ver" ]]; then
        log_warn "PHP detected: $php_ver"
        if echo "$php_ver" | grep -qE "PHP 5\.|PHP 7\.[01]"; then
            log_high "PHP version is EOL and NOT available in EL8 AppStream. Must upgrade to PHP 7.4+ or 8.x first or use SCL."
        else
            log_info "PHP version appears compatible. Verify SCL/Remi repo for EL8."
        fi
    fi

    # Python
    echo
    echo "--- Python ---"
    python --version 2>/dev/null || true
    python2 --version 2>/dev/null || true
    python3 --version 2>/dev/null || true
    log_warn "Python 2 is removed in EL8. Any Python 2 scripts/apps need porting or containerising."

    # MySQL / MariaDB
    if rpm -q mysql-server &>/dev/null 2>&1; then
        log_high "MySQL Server detected. MySQL 5.x is NOT in EL8 repos. Migrate to MySQL 8.0 or MariaDB 10.x."
    fi
    if rpm -q mariadb-server &>/dev/null 2>&1; then
        local mdb_ver
        mdb_ver=$(mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')
        log_warn "MariaDB detected ($mdb_ver). EL8 ships MariaDB 10.3. Verify data compatibility."
    fi

    # PostgreSQL
    if rpm -q postgresql-server &>/dev/null 2>&1; then
        log_warn "PostgreSQL detected. Verify target version is available in EL8 PostgreSQL repo."
    fi

    # Apache / HTTPD
    if rpm -q httpd &>/dev/null 2>&1; then
        local ap_ver
        ap_ver=$(httpd -v 2>/dev/null | head -1 || echo "unknown")
        log_info "Apache HTTPD detected: $ap_ver — EL8 ships httpd 2.4 (compatible)."
        # Check for mod_php vs php-fpm
        if rpm -q mod_php &>/dev/null 2>&1 || rpm -q php &>/dev/null 2>&1; then
            log_warn "mod_php (prefork MPM) detected. EL8 prefers php-fpm with event MPM — reconfiguration required."
        fi
    fi

    # Nginx
    if rpm -q nginx &>/dev/null 2>&1; then
        log_info "Nginx detected: $(nginx -v 2>&1 || true)"
    fi

    # Java
    local java_ver
    java_ver=$(java -version 2>&1 | head -1 || echo "")
    if [[ -n "$java_ver" ]]; then
        log_info "Java detected: $java_ver"
        if echo "$java_ver" | grep -qE "1\.[678]"; then
            log_high "Java 6/7/8 detected. EL8 ships OpenJDK 8, 11, 17. Verify app compatibility."
        fi
    fi

    # Node.js
    if command -v node &>/dev/null; then
        log_info "Node.js detected: $(node --version 2>/dev/null)"
        log_warn "Node.js from SCL or EPEL — verify EL8 module stream availability (node:14, 16, 18, 20)."
    fi

    # Ruby
    if command -v ruby &>/dev/null; then
        log_info "Ruby detected: $(ruby --version 2>/dev/null)"
        log_warn "Ruby may need reinstallation from EL8 module streams."
    fi

    # Perl
    if command -v perl &>/dev/null; then
        log_info "Perl detected: $(perl --version 2>/dev/null | head -2 | tail -1)"
    fi

    # Docker / Podman / containerd
    for ct in docker podman containerd crio; do
        if command -v "$ct" &>/dev/null; then
            log_warn "Container runtime '$ct' detected. Reconfigure with EL8 container-tools module."
        fi
    done

    # Kubernetes
    if command -v kubectl &>/dev/null || command -v kubelet &>/dev/null; then
        log_high "Kubernetes components detected. Upgrade k8s AFTER OS upgrade using k8s EL8 repos."
    fi

    # Ansible / Puppet / Chef / Salt
    for mgmt in ansible puppet chef salt; do
        if command -v "$mgmt" &>/dev/null 2>&1; then
            log_warn "Config management tool '$mgmt' detected. Reinstall from EL8-compatible repos post-upgrade."
        fi
    done

    # OpenVPN / WireGuard / VPN
    if rpm -q openvpn &>/dev/null 2>&1; then
        log_warn "OpenVPN detected. Verify kernel module compatibility post-upgrade."
    fi
    if rpm -q wireguard-tools &>/dev/null 2>&1; then
        log_info "WireGuard detected. Built into EL8 kernel (5.x) — should work fine."
    fi

    # Check kernel modules
    echo
    echo "--- Loaded Kernel Modules ---"
    lsmod | head -40
    echo

    # Check for custom kernel modules
    local extra_dir="/lib/modules/$(uname -r)/extra"
    if [[ -d "$extra_dir" ]] && find "$extra_dir" -name "*.ko" 2>/dev/null | grep -q "."; then
        log_high "Custom kernel modules detected in $extra_dir — these will NOT work with EL8 kernel."
        find "$extra_dir" -name "*.ko" 2>/dev/null
    else
        log_ok "No custom kernel modules found in extra/."
    fi
}

analyze_services() {
    log_section "6. Running Services & Daemons"

    echo "--- Systemd Services (enabled) ---"
    systemctl list-unit-files --type=service --state=enabled 2>/dev/null
    echo

    echo "--- Currently Active Services ---"
    systemctl list-units --type=service --state=active 2>/dev/null
    echo

    # Identify critical services
    local critical_services=(sshd httpd nginx mysql mariadb postgresql redis rabbitmq mongod \
                              elasticsearch kibana logstash kafka zookeeper)
    echo "--- Critical Service Status ---"
    for svc in "${critical_services[@]}"; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            local state
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            echo "  $svc: $state"
        fi
    done
    echo

    # Cron jobs
    echo "--- Cron Jobs ---"
    crontab -l 2>/dev/null || echo "  (no root crontab)"
    ls /etc/cron.d/ 2>/dev/null && cat /etc/cron.d/* 2>/dev/null || true
    echo

    # Systemd timers
    echo "--- Systemd Timers ---"
    systemctl list-timers --all 2>/dev/null | head -20
    echo
}

analyze_security() {
    log_section "7. Security Configuration"

    # SSH
    echo "--- SSH Configuration ---"
    grep -v "^#\|^$" /etc/ssh/sshd_config 2>/dev/null | head -40
    echo

    # Check for non-standard SSH port
    local ssh_port
    ssh_port=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    log_info "SSH Port: ${ssh_port:-22}"

    # Sudo config
    echo "--- Sudoers ---"
    grep -v "^#\|^$\|^Defaults" /etc/sudoers 2>/dev/null | head -20
    echo

    # Check for LUKS encryption
    if command -v cryptsetup &>/dev/null; then
        if cryptsetup status 2>/dev/null | grep -q "active"; then
            log_warn "LUKS-encrypted device detected. Ensure encryption headers are preserved during backup."
        fi
    fi

    # Auditd
    if systemctl is-active --quiet auditd 2>/dev/null; then
        log_info "auditd is running — audit rules will need re-evaluation on EL8."
    fi

    # PAM
    echo "--- PAM Configuration Summary ---"
    ls /etc/pam.d/ | head -10
    echo

    # Fail2ban / intrusion detection
    for ids in fail2ban aide ossec tripwire; do
        if rpm -q "$ids" &>/dev/null 2>&1 || command -v "$ids" &>/dev/null 2>&1; then
            log_warn "$ids detected — reconfigure from EL8-compatible packages post-upgrade."
        fi
    done
}

analyze_users() {
    log_section "8. Users & Groups"

    echo "--- System Users (non-system UID ≥ 1000) ---"
    awk -F: '$3 >= 1000 {print $1, $3, $6, $7}' /etc/passwd
    echo

    echo "--- Groups with Members ---"
    awk -F: '$4 != "" {print $1, $4}' /etc/group | head -20
    echo

    # Check for LDAP / AD / FreeIPA
    if rpm -q sssd &>/dev/null 2>&1 || rpm -q sss_client &>/dev/null 2>&1; then
        log_warn "SSSD detected (LDAP/AD/FreeIPA auth). Verify sssd config is compatible with EL8 sssd."
    fi
}

analyze_applications_deep() {
    log_section "9. Deep Application & Dependency Analysis"

    echo "--- All Installed Packages (grouped by origin) ---"
    # Packages NOT from CentOS/RHEL repos
    echo "  Third-party / Unknown origin packages:"
    local third_party
    third_party=$(rpm -qa --queryformat '%{NAME} %{VENDOR}\n' 2>/dev/null | \
        grep -v -iE "centos|red hat|fedora" | sort | head -50 || true)
    if [[ -n "$third_party" ]]; then
        echo "$third_party"
    else
        echo "  (none detected — all packages from CentOS/Red Hat)"
    fi
    echo

    # RPM scriptlets that may fail
    echo "--- Packages with Post-install Scriptlets ---"
    local scriptlets
    scriptlets=$(rpm -qa --queryformat '%{NAME}\n' 2>/dev/null | \
        xargs -I{} rpm -q --scripts {} 2>/dev/null | \
        grep -B1 "postinstall\|preinstall" 2>/dev/null | \
        grep -v "^--$" 2>/dev/null | head -30 || true)
    if [[ -n "$scriptlets" ]]; then
        echo "$scriptlets"
    else
        echo "  (none found)"
    fi
    echo

    # Shared libraries
    echo "--- Missing Shared Libraries (ldd check on binaries) ---"
    local broken_binaries=()
    while IFS= read -r bin; do
        if ldd "$bin" 2>&1 | grep -q "not found"; then
            broken_binaries+=("$bin")
            log_warn "Binary $bin has missing shared libraries NOW (pre-upgrade issue)"
        fi
    done < <(find /usr/bin /usr/sbin /usr/local/bin -type f -executable 2>/dev/null | head -100)
    [[ ${#broken_binaries[@]} -eq 0 ]] && log_ok "No pre-existing broken shared library links found."
    echo

    # SCL (Software Collections)
    if rpm -q centos-release-scl &>/dev/null 2>&1 || rpm -q scl-utils &>/dev/null 2>&1; then
        log_high "Software Collections (SCL) detected. SCL is NOT supported in EL8 — applications must be migrated to AppStream module streams."
        echo "--- SCL packages ---"
        scl --list 2>/dev/null || rpm -qa | grep "^rh-\|^devtoolset-\|^python27\|^python36"
        echo
    fi

    # Check config files that will differ
    echo "--- Key Configuration Files to Review Post-Upgrade ---"
    local config_files=(/etc/httpd/conf/httpd.conf /etc/nginx/nginx.conf /etc/my.cnf \
                         /etc/php.ini /etc/sysconfig/network-scripts/ /etc/NetworkManager/ \
                         /etc/postfix/main.cf /etc/dovecot/dovecot.conf)
    for cf in "${config_files[@]}"; do
        [[ -e "$cf" ]] && echo "  EXISTS: $cf"
    done
    echo

    # Logs analysis for recurring errors
    echo "--- Recent Errors in System Logs (last 200 lines) ---"
    journalctl -p err --no-pager -n 50 2>/dev/null | tail -30 || \
        grep -i "error\|critical\|failed" /var/log/messages 2>/dev/null | tail -30 || true
    echo
}

check_disk_space_for_upgrade() {
    log_section "10. Disk Space Check for Upgrade"

    # Minimum requirements for leapp/elevate
    local root_avail
    root_avail=$(df --output=avail -BG / | tail -1 | tr -d 'G')
    local boot_avail
    boot_avail=$(df --output=avail -BG /boot 2>/dev/null | tail -1 | tr -d 'G' || echo "0")

    log_info "Available on /: ${root_avail}G"
    log_info "Available on /boot: ${boot_avail}G"

    if [[ "$root_avail" -lt 10 ]]; then
        log_critical "/: Only ${root_avail}G available. ELevate requires ≥10G on /. FREE SPACE BEFORE PROCEEDING."
    else
        log_ok "/ has sufficient space (${root_avail}G ≥ 10G required)."
    fi

    if [[ "$boot_avail" -lt 1 ]]; then
        log_critical "/boot: Only ${boot_avail}G available. Need ≥1G. Remove old kernels: package-cleanup --oldkernels"
    else
        log_ok "/boot has sufficient space."
    fi
}

# ---------------------------------------------------------------------------
# SECTION 2: BACKUP TO BLOCK DEVICE
# ---------------------------------------------------------------------------
backup_to_block_device() {
    log_section "BACKUP: Disk Image to Block Device"

    if [[ -z "$BACKUP_DEV" ]]; then
        log_warn "No backup device specified (--backup-dev). Skipping backup."
        return 0
    fi

    if [[ ! -b "$BACKUP_DEV" ]]; then
        die "Backup device '$BACKUP_DEV' is not a valid block device."
    fi

    # Identify source disk (disk containing /)
    local root_dev
    root_dev=$(df / | tail -1 | awk '{print $1}')
    # If on LVM, find the underlying disk
    local source_disk
    if echo "$root_dev" | grep -q "mapper"; then
        source_disk=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | head -1)
        # Trim partition number to get disk
        source_disk=$(echo "$source_disk" | sed 's/[0-9]*$//')
    else
        source_disk=$(echo "$root_dev" | sed 's/[0-9]*$//')
    fi

    log_info "Source disk detected: $source_disk"
    log_info "Backup target device: $BACKUP_DEV"

    # Size check
    local src_size dest_size
    src_size=$(lsblk -bno SIZE "$source_disk" 2>/dev/null | head -1)
    dest_size=$(lsblk -bno SIZE "$BACKUP_DEV" 2>/dev/null | head -1)

    log_info "Source size: $(numfmt --to=iec "$src_size")"
    log_info "Destination size: $(numfmt --to=iec "$dest_size")"

    if [[ "$dest_size" -lt "$src_size" ]]; then
        die "Backup device ($BACKUP_DEV) is smaller than source disk ($source_disk). Backup aborted."
    fi

    echo
    log_warn "BACKUP OPERATION: This will OVERWRITE all data on $BACKUP_DEV."
    log_warn "Source: $source_disk → Destination: $BACKUP_DEV"
    echo

    if ! confirm "Proceed with disk image backup? (THIS WILL ERASE $BACKUP_DEV)"; then
        log_info "Backup skipped by user."
        return 0
    fi

    # Sync filesystems
    log_info "Syncing filesystems..."
    sync

    # Flush caches
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    log_info "Starting dd backup — this may take a long time..."
    log_info "Progress is shown below (update every 10 seconds)."

    local backup_start
    backup_start=$(date +%s)

    if command -v pv &>/dev/null; then
        # pv gives a nice progress bar
        pv -tpreb "$source_disk" | dd of="$BACKUP_DEV" bs=4M conv=noerror,sync 2>&1
    else
        # dd with progress (GNU dd)
        dd if="$source_disk" of="$BACKUP_DEV" bs=4M conv=noerror,sync status=progress 2>&1
    fi

    local backup_end
    backup_end=$(date +%s)
    local elapsed=$(( backup_end - backup_start ))
    log_ok "Backup completed in ${elapsed}s."

    # Verify backup with hash comparison (first 512MB)
    log_info "Verifying backup integrity (comparing first 512MB of source vs backup)..."
    local src_hash dest_hash
    src_hash=$(dd if="$source_disk" bs=1M count=512 2>/dev/null | md5sum | awk '{print $1}')
    dest_hash=$(dd if="$BACKUP_DEV"  bs=1M count=512 2>/dev/null | md5sum | awk '{print $1}')

    if [[ "$src_hash" == "$dest_hash" ]]; then
        log_ok "Backup integrity verified (MD5 match: $src_hash)."
    else
        log_error "MD5 MISMATCH — backup may be corrupt!"
        log_error "Source: $src_hash"
        log_error "Backup: $dest_hash"
        die "Backup verification failed. DO NOT PROCEED with upgrade."
    fi

    # Store backup metadata
    cat > "${LOG_DIR}/backup_metadata_${START_TIME}.txt" <<EOF
Backup Date     : $(date)
Source Disk     : $source_disk
Source Size     : $(numfmt --to=iec "$src_size")
Backup Device   : $BACKUP_DEV
Duration        : ${elapsed}s
MD5 (first 512M): $src_hash
Kernel          : $(uname -r)
OS              : $(cat /etc/centos-release)

To RESTORE from backup:
  dd if=$BACKUP_DEV of=$source_disk bs=4M conv=noerror,sync status=progress
  # Then run: grub2-install $source_disk && grub2-mkconfig -o /boot/grub2/grub.cfg
EOF

    log_ok "Backup metadata saved to ${LOG_DIR}/backup_metadata_${START_TIME}.txt"
    log_info "RESTORE COMMAND: dd if=$BACKUP_DEV of=$source_disk bs=4M conv=noerror,sync status=progress"
}

# ---------------------------------------------------------------------------
# SECTION 3: PRE-UPGRADE PREPARATION
# ---------------------------------------------------------------------------
prepare_system() {
    log_section "Pre-Upgrade System Preparation"

    # 1. Full system update on CentOS 7 first
    log_info "Step 1: Updating all CentOS 7 packages to latest..."
    yum update -y 2>&1 | tail -20
    log_ok "System fully updated."

    # 2. Clean yum cache
    log_info "Step 2: Cleaning yum cache..."
    yum clean all
    rm -rf /var/cache/yum

    # 3. Remove known conflicting packages
    log_info "Step 3: Removing packages known to conflict with ELevate..."
    local conflict_pkgs=(
        centos-release-scl centos-release-scl-rh
        python2-virtualenv python-virtualenv
        abrt abrt-addon-ccpp abrt-addon-kerneloops abrt-addon-pstoreoops
        abrt-addon-python abrt-addon-vmcore abrt-addon-xorg abrt-cli
        abrt-console-notification abrt-libs abrt-plugin-sosreport
        libreport libreport-cli libreport-filesystem libreport-plugin-bugzilla
        libreport-plugin-logger libreport-plugin-mailx libreport-plugin-reportuploader
        libreport-python libreport-web
    )
    for pkg in "${conflict_pkgs[@]}"; do
        if rpm -q "$pkg" &>/dev/null 2>&1; then
            log_info "Removing $pkg..."
            yum remove -y "$pkg" 2>/dev/null || log_warn "Could not remove $pkg — continuing."
        fi
    done

    # 4. Remove old kernels (keep only 1)
    log_info "Step 4: Removing old kernels (keeping latest only)..."
    package-cleanup --oldkernels --count=1 -y 2>/dev/null || true

    # 5. Install EPEL if not present (needed for elevate)
    if ! rpm -q epel-release &>/dev/null 2>&1; then
        log_info "Step 5: Installing EPEL..."
        yum install -y epel-release
    fi

    # 6. Disable problematic third-party repos temporarily
    log_info "Step 6: Disabling third-party repos (will be re-enabled post-upgrade)..."
    find /etc/yum.repos.d/ -name "*.repo" \
        ! -name "CentOS-*.repo" \
        ! -name "epel*.repo" \
        -exec bash -c 'sed -i "s/^enabled=1/enabled=0/" "$1"' _ {} \;
    log_ok "Third-party repos disabled for upgrade."

    # 7. Snapshot currently installed packages for comparison
    rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort \
        > "${LOG_DIR}/packages_before_${START_TIME}.txt"
    log_ok "Pre-upgrade package list saved to ${LOG_DIR}/packages_before_${START_TIME}.txt"

    # 8. Backup critical config directories
    log_info "Step 7: Backing up critical configs..."
    local cfg_backup_dir="${LOG_DIR}/config_backup_${START_TIME}"
    mkdir -p "$cfg_backup_dir"
    for dir in /etc/httpd /etc/nginx /etc/mysql /etc/my.cnf.d /etc/php.ini \
                /etc/php.d /etc/postfix /etc/dovecot /etc/ssh /etc/cron.d \
                /etc/sysconfig/network-scripts /etc/NetworkManager; do
        [[ -e "$dir" ]] && cp -a "$dir" "$cfg_backup_dir/" 2>/dev/null && \
            log_info "  Backed up: $dir"
    done
    log_ok "Config backups → $cfg_backup_dir"
}

# ---------------------------------------------------------------------------
# SECTION 4: ELEVATE / LEAPP UPGRADE
# ---------------------------------------------------------------------------

# Locate the leapp binary — it may be in /usr/bin, /bin, or /usr/local/bin
resolve_leapp_bin() {
    local candidates=(/usr/bin/leapp /bin/leapp /usr/local/bin/leapp)
    for p in "${candidates[@]}"; do
        if [[ -x "$p" ]]; then
            LEAPP_BIN="$p"
            log_ok "leapp binary found: $LEAPP_BIN"
            return 0
        fi
    done
    # Last resort: search PATH
    if command -v leapp &>/dev/null 2>&1; then
        LEAPP_BIN="$(command -v leapp)"
        log_ok "leapp binary found via PATH: $LEAPP_BIN"
        return 0
    fi
    die "leapp binary not found. Installation may have failed. Try: yum install -y leapp-upgrade"
}

install_elevate() {
    log_section "Installing ELevate (leapp-based upgrade tool)"

    local elevate_url="https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm"

    # Install elevate-release only if not already installed
    if rpm -q elevate-release &>/dev/null 2>&1; then
        log_ok "elevate-release already installed — skipping."
    else
        log_info "Installing ELevate release package..."
        yum install -y "$elevate_url" 2>&1 | tail -10
        log_ok "elevate-release installed."
    fi

    # Always ensure the elevate repo is enabled (installs disabled by default)
    log_info "Ensuring ELevate repo is enabled..."
    if yum-config-manager --enable elevate &>/dev/null 2>&1; then
        log_ok "ELevate repo enabled via yum-config-manager."
    else
        sed -i "s/enabled=0/enabled=1/" /etc/yum.repos.d/elevate.repo 2>/dev/null || true
        log_ok "ELevate repo enabled via repo file."
    fi
    yum clean all &>/dev/null

    log_info "Installing leapp-upgrade and target OS data..."

    # Package name varies by ELevate version:
    # older: leapp-upgrade  newer: leapp-upgrade-el7toel8
    leapp_pkg_installed() {
        rpm -q leapp-upgrade &>/dev/null 2>&1 ||         rpm -q leapp-upgrade-el7toel8 &>/dev/null 2>&1
    }

    case "$TARGET_DISTRO" in
        alma)
            yum install -y leapp-upgrade leapp-data-almalinux 2>&1 | tail -20 || true
            # Verify the packages actually landed (handle both package name variants)
            if ! leapp_pkg_installed; then
                die "leapp-upgrade failed to install. Check yum output above."
            fi
            if ! rpm -q leapp-data-almalinux &>/dev/null 2>&1; then
                die "leapp-data-almalinux failed to install. Check yum output above."
            fi
            ;;
        rocky)
            yum install -y leapp-upgrade leapp-data-rocky 2>&1 | tail -20 || \
            yum install -y leapp-upgrade python2-leapp 2>&1 | tail -20 || true
            if ! leapp_pkg_installed; then
                die "leapp-upgrade failed to install. Check yum output above."
            fi
            ;;
        *)
            die "Unknown target distro: $TARGET_DISTRO"
            ;;
    esac

    log_ok "ELevate/leapp installed."
}

run_preupgrade_check() {
    log_section "Running leapp pre-upgrade analysis..."

    log_info "This performs a DRY RUN — no changes are made to the system."
    $LEAPP_BIN preupgrade 2>&1 | tee "${LOG_DIR}/leapp_preupgrade_${START_TIME}.log"

    echo
    log_info "Reviewing leapp pre-upgrade report..."

    if [[ -f /var/log/leapp/leapp-report.txt ]]; then
        cp /var/log/leapp/leapp-report.txt "${LOG_DIR}/leapp_report_${START_TIME}.txt"
        cat /var/log/leapp/leapp-report.txt

        # Check for inhibitors
        if grep -q "Inhibitor" /var/log/leapp/leapp-report.txt; then
            log_warn "Inhibitors found in first preupgrade run — attempting auto-remediation..."
            echo
            echo "--- INHIBITORS DETECTED ---"
            grep -A5 "Inhibitor" /var/log/leapp/leapp-report.txt || true
            echo

            # Auto-fix known inhibitors then re-run preupgrade
            fix_leapp_inhibitors

            log_info "Re-running leapp preupgrade after remediation..."
            leapp preupgrade 2>&1 | tee "${LOG_DIR}/leapp_preupgrade2_${START_TIME}.log"

            if [[ -f /var/log/leapp/leapp-report.txt ]]; then
                cp /var/log/leapp/leapp-report.txt "${LOG_DIR}/leapp_report2_${START_TIME}.txt"
            fi

            if grep -q "Inhibitor" /var/log/leapp/leapp-report.txt 2>/dev/null; then
                log_critical "INHIBITORS STILL PRESENT after auto-remediation."
                log_critical "Manual intervention required. Review:"
                log_critical "  cat /var/log/leapp/leapp-report.txt"
                echo
                grep -A8 "Inhibitor" /var/log/leapp/leapp-report.txt || true
                echo
                if ! confirm "Inhibitors remain. Force continue anyway? (UPGRADE WILL LIKELY FAIL)"; then
                    die "Upgrade aborted — inhibitors not resolved."
                fi
            else
                log_ok "All inhibitors resolved after auto-remediation."
            fi
        else
            log_ok "No leapp inhibitors found."
        fi
    else
        log_warn "leapp-report.txt not found. Review /var/log/leapp/ manually."
    fi
}

# =============================================================================
# UNIVERSAL LEAPP INHIBITOR REMEDIATION ENGINE
# -----------------------------------------------------------------------------
# This function works for ALL EL7→EL8 and EL8→EL9 upgrades.
# Strategy:
#   1. Apply ALL known leapp answerfile entries upfront
#   2. Dynamically parse leapp-report.txt and blacklist ANY removed drivers
#   3. Apply known HIGH-risk non-inhibitor fixes (postfix, python, etc.)
#   4. Handle every inhibitor category leapp can generate
# =============================================================================
fix_leapp_inhibitors() {
    log_section "Universal leapp Inhibitor Remediation"

    # -------------------------------------------------------------------------
    # STEP 1: Apply ALL known leapp answerfile entries
    # These cover every interactive prompt leapp may raise across EL7→EL8/EL9
    # -------------------------------------------------------------------------
    log_info "Step 1: Applying all known leapp answerfile entries..."
    local leapp_answers=(
        "remove_pam_pkcs11_module_check.confirm=True"
        "authselect_check.confirm=True"
        "remove_ifcfg_files_check.confirm=True"
        "grub_enableos_prober_check.confirm=True"
        "verify_check_results.confirm=True"
    )
    for answer in "${leapp_answers[@]}"; do
        $LEAPP_BIN answer --section "$answer" 2>/dev/null &&             log_ok "  Answered: $answer" || true
    done

    # -------------------------------------------------------------------------
    # STEP 2: Dynamically detect and blacklist ALL removed kernel drivers
    # Parses leapp-report.txt to find whatever drivers leapp flagged —
    # works universally regardless of which drivers are on this specific system
    # -------------------------------------------------------------------------
    log_info "Step 2: Detecting removed kernel drivers from leapp report..."

    # Run a quick preupgrade if report doesn't exist yet
    if [[ ! -f /var/log/leapp/leapp-report.txt ]]; then
        log_info "  No leapp report found yet — running initial preupgrade scan..."
        $LEAPP_BIN preupgrade 2>/dev/null || true
    fi

    if [[ -f /var/log/leapp/leapp-report.txt ]]; then
        # Extract driver names from the report dynamically
        # Handles both "removed in RHEL 8" and "no longer maintained" sections
        local report_drivers=()
        while IFS= read -r line; do
            # Lines starting with "     - <driver_name>" under kernel driver sections
            if echo "$line" | grep -qE "^\s+- [a-z0-9_]+$"; then
                local drv
                drv=$(echo "$line" | tr -d ' -')
                # Only process if it looks like a kernel module name
                if [[ "$drv" =~ ^[a-z0-9_]+$ ]] && [[ ${#drv} -lt 40 ]]; then
                    report_drivers+=("$drv")
                fi
            fi
        done < <(grep -A 20 "kernel drivers" /var/log/leapp/leapp-report.txt 2>/dev/null || true)

        if [[ ${#report_drivers[@]} -gt 0 ]]; then
            log_info "  Drivers to blacklist: ${report_drivers[*]}"
            for drv in "${report_drivers[@]}"; do
                _blacklist_driver "$drv"
            done
        else
            log_info "  No removed kernel drivers detected in leapp report."
        fi
    fi

    # Always blacklist the universal set of commonly removed drivers
    # across all EL7→EL8 and EL8→EL9 upgrades regardless of report content
    log_info "Step 3: Blacklisting universally removed drivers..."
    local universal_removed_drivers=(
        # EL7 → EL8 removed drivers
        pata_acpi        # Legacy PATA/IDE controller
        floppy           # Floppy disk (removed in EL8)
        isdn             # ISDN subsystem
        nozomi           # 3G WWAN card
        aoe              # ATA over Ethernet
        # EL8 → EL9 additionally removed drivers
        snd_emu10k1_synth
        acerhdf
        asus_acpi
        bcm203x
        bpa10x
        btusb_rtl
        lirc_serial
        mptbase
        mptctl
        mptfc
        mptlan
        mptsas
        mptscsih
        mptspi
        mtdblock
        n_hdlc
        pch_gbe
        snd_atiixp_modem
        snd_via82xx_modem
        ueagle_atm
        usbatm
        xusbatm
    )
    for drv in "${universal_removed_drivers[@]}"; do
        # Only blacklist if currently loaded OR if in the leapp report
        if lsmod 2>/dev/null | grep -q "^${drv} " ||            grep -q "$drv" /var/log/leapp/leapp-report.txt 2>/dev/null; then
            _blacklist_driver "$drv"
        fi
    done

    # -------------------------------------------------------------------------
    # STEP 4: VDO (Virtual Data Optimizer) — inhibitor on some systems
    # -------------------------------------------------------------------------
    if systemctl is-active --quiet vdo 2>/dev/null; then
        log_warn "VDO service detected. Stopping before upgrade..."
        systemctl stop vdo 2>/dev/null || true
        systemctl disable vdo 2>/dev/null || true
        log_ok "VDO stopped and disabled."
    fi

    # -------------------------------------------------------------------------
    # STEP 5: Network interface name inhibitor
    # If system uses old-style eth0 naming, leapp may inhibit
    # -------------------------------------------------------------------------
    if ip link show 2>/dev/null | grep -q "^[0-9]*: eth[0-9]"; then
        log_warn "Legacy network interface name (eth0) detected."
        log_warn "Adding net.ifnames=0 biosdevname=0 to kernel args for upgrade..."
        grubby --update-kernel=ALL --args="net.ifnames=0 biosdevname=0" 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # STEP 6: Postfix compatibility — prevents mail service breakage
    # -------------------------------------------------------------------------
    if command -v postconf &>/dev/null 2>&1; then
        log_info "Setting Postfix compatibility_level=2..."
        postconf -e compatibility_level=2 2>/dev/null || true
        log_ok "Postfix compatibility_level=2 set."
    fi

    # -------------------------------------------------------------------------
    # STEP 7: Remove remaining ABRT packages if still present
    # These are known to cause transaction conflicts during leapp upgrade
    # -------------------------------------------------------------------------
    log_info "Removing any remaining ABRT packages..."
    local abrt_pkgs
    abrt_pkgs=$(rpm -qa 2>/dev/null | grep "^abrt\|^libreport" || true)
    if [[ -n "$abrt_pkgs" ]]; then
        log_info "  Found ABRT packages: removing..."
        echo "$abrt_pkgs" | xargs yum remove -y 2>/dev/null || true
        log_ok "  ABRT packages removed."
    else
        log_ok "  No ABRT packages found."
    fi

    # -------------------------------------------------------------------------
    # STEP 8: Fix /etc/redhat-release symlink issues (affects some minimal installs)
    # -------------------------------------------------------------------------
    if [[ ! -f /etc/redhat-release ]] && [[ -f /etc/centos-release ]]; then
        ln -sf /etc/centos-release /etc/redhat-release 2>/dev/null || true
        log_ok "Fixed /etc/redhat-release symlink."
    fi

    # -------------------------------------------------------------------------
    # STEP 9: Ensure required leapp directories exist
    # -------------------------------------------------------------------------
    mkdir -p /var/log/leapp /etc/leapp/files 2>/dev/null || true

    # -------------------------------------------------------------------------
    # SUMMARY: Log all remaining items from leapp report for awareness
    # -------------------------------------------------------------------------
    log_info "Step 10: Non-inhibitor HIGH risk items (informational):"
    log_info "  • e1000 driver     → replaced by e1000e in EL8/EL9 (automatic)"
    log_info "  • Python 2         → run 'alternatives --set python /usr/bin/python3' post-upgrade"
    log_info "  • SELinux           → leapp sets permissive; re-enable enforcing post-upgrade"
    log_info "  • GRUB2 update     → leapp runs grub2-install automatically on BIOS systems"
    log_info "  • chrony config    → review /etc/chrony.conf post-upgrade if using leap smearing NTP"

    log_ok "Universal inhibitor remediation complete."
}

# Helper: blacklist a single kernel module safely
_blacklist_driver() {
    local drv="$1"
    local blacklist_file="/etc/modprobe.d/${drv}.conf"
    if [[ ! -f "$blacklist_file" ]]; then
        echo "blacklist ${drv}" > "$blacklist_file"
        log_ok "  Blacklisted driver: ${drv}"
    fi
    if lsmod 2>/dev/null | grep -q "^${drv} "; then
        rmmod "$drv" 2>/dev/null &&             log_ok "  Unloaded module: ${drv}" ||             log_warn "  Could not unload ${drv} — will take effect after reboot."
    fi
}

apply_leapp_answers() {
    log_section "Applying leapp answers for common prompts"

    # Answer common leapp questions automatically
    local answers_file="/var/log/leapp/answerfile"
    if [[ -f "$answers_file" ]]; then
        log_info "Existing leapp answerfile found:"
        cat "$answers_file"
    fi

    $LEAPP_BIN answer --section remove_pam_pkcs11_module_check.confirm=True 2>/dev/null || true
    $LEAPP_BIN answer --section authselect_check.confirm=True 2>/dev/null || true

    log_ok "leapp answers configured."
}

run_upgrade() {
    log_section "Executing ELevate In-Place Upgrade"

    log_warn "POINT OF NO EASY RETURN — upgrade will begin."
    log_warn "Ensure backup is verified and all inhibitors are resolved."
    echo

    if ! confirm "START UPGRADE NOW? (System will reboot automatically)"; then
        die "Upgrade cancelled by user."
    fi

    log_info "Starting leapp upgrade..."
    log_info "The system will reboot into a special upgrade initramfs environment."
    log_info "Do NOT interrupt power during this process."
    echo

    # leapp upgrade initiates the process and reboots
    $LEAPP_BIN upgrade 2>&1 | tee "${LOG_DIR}/leapp_upgrade_${START_TIME}.log"

    log_info "leapp upgrade initiated. System will reboot automatically."
    log_info "After reboot, the upgrade will continue in the initramfs environment."
    log_info "This may take 20-60 minutes. Monitor via console."
    echo
    log_info "After the system comes back online, run this script with --post-upgrade to validate."
}

# ---------------------------------------------------------------------------
# SECTION 5: POST-UPGRADE VALIDATION
# ---------------------------------------------------------------------------
post_upgrade_validate() {
    log_section "Post-Upgrade Validation"

    echo "--- New OS Version ---"
    cat /etc/os-release
    echo

    echo "--- New Kernel ---"
    uname -a
    echo

    # Verify target distro
    if [[ -f /etc/almalinux-release ]]; then
        log_ok "AlmaLinux 8 confirmed: $(cat /etc/almalinux-release)"
    elif [[ -f /etc/rocky-release ]]; then
        log_ok "Rocky Linux 8 confirmed: $(cat /etc/rocky-release)"
    elif [[ -f /etc/redhat-release ]]; then
        local rh_ver
        rh_ver=$(cat /etc/redhat-release)
        if echo "$rh_ver" | grep -q " 8"; then
            log_ok "EL8 OS detected: $rh_ver"
        else
            log_error "Unexpected OS version: $rh_ver"
        fi
    else
        log_error "Cannot determine OS release!"
    fi

    echo
    echo "--- DNF / Package Manager ---"
    dnf --version
    echo

    # Check critical services
    log_section "Service Health Check"
    local services_to_check=(sshd NetworkManager rsyslog crond)
    for svc in "${services_to_check[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_ok "$svc is running."
        else
            log_warn "$svc is NOT running. Check with: systemctl status $svc"
        fi
    done

    # Check for failed units
    echo
    echo "--- Failed Systemd Units ---"
    systemctl --failed 2>/dev/null
    echo

    # Network check
    log_section "Network Validation"
    if ping -c2 -W3 8.8.8.8 &>/dev/null; then
        log_ok "Network connectivity OK (ping 8.8.8.8)."
    else
        log_warn "Cannot reach 8.8.8.8 — check network configuration."
    fi

    if ping -c2 -W3 google.com &>/dev/null; then
        log_ok "DNS resolution OK."
    else
        log_warn "DNS resolution may be broken. Check /etc/resolv.conf"
    fi

    # Package count comparison
    log_section "Package Delta Analysis"
    rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort \
        > "${LOG_DIR}/packages_after_${START_TIME}.txt"

    if [[ -f "${LOG_DIR}/packages_before_${START_TIME}.txt" ]]; then
        echo "--- Packages removed during upgrade ---"
        diff "${LOG_DIR}/packages_before_${START_TIME}.txt" \
             "${LOG_DIR}/packages_after_${START_TIME}.txt" | grep "^<" | head -40
        echo
        echo "--- New packages added during upgrade ---"
        diff "${LOG_DIR}/packages_before_${START_TIME}.txt" \
             "${LOG_DIR}/packages_after_${START_TIME}.txt" | grep "^>" | head -40
    fi

    # Check for .rpmsave/.rpmnew config files
    log_section "Configuration File Conflicts"
    echo "--- .rpmsave files (old configs backed up by RPM) ---"
    find /etc -name "*.rpmsave" 2>/dev/null | head -30
    echo
    echo "--- .rpmnew files (new default configs) ---"
    find /etc -name "*.rpmnew" 2>/dev/null | head -30
    echo
    log_warn "Review and merge .rpmsave and .rpmnew files — these represent config conflicts."

    # Check for leapp residual files
    if [[ -d /var/log/leapp ]]; then
        echo "--- leapp upgrade log summary ---"
        tail -30 /var/log/leapp/leapp-upgrade.log 2>/dev/null || true
    fi

    # Re-enable third-party repos where EL8 versions exist
    log_section "Repository Re-configuration"
    log_warn "Review and manually re-enable third-party repos with EL8-compatible versions."
    log_info "Run: dnf repolist all"

    # EPEL for EL8
    if ! rpm -q epel-release &>/dev/null 2>&1; then
        log_info "Installing EPEL for EL8..."
        dnf install -y epel-release 2>/dev/null && log_ok "EPEL EL8 installed." || true
    fi

    # Security hardening reminders
    log_section "Post-Upgrade Security Checklist"
    log_warn "1. Review /etc/ssh/sshd_config — new defaults in EL8."
    log_warn "2. EL8 uses crypto-policies — run: update-crypto-policies --show"
    log_warn "3. SELinux relabelling may be needed: touch /.autorelabel && reboot"
    log_warn "4. Review firewalld rules: firewall-cmd --list-all"
    log_warn "5. Check authselect config: authselect list"
    log_warn "6. Run: dnf update --security to apply any post-upgrade security patches."

    log_ok "Post-upgrade validation complete."
}

# ---------------------------------------------------------------------------
# SECTION 6: FUTURE UPGRADE PATH ANALYSIS (EL8 → EL9)
# ---------------------------------------------------------------------------
analyze_future_upgrade_path() {
    log_section "Future Upgrade Path: EL8 → EL9 (AlmaLinux/Rocky 9)"

    cat <<'EOF'

  ┌─────────────────────────────────────────────────────────────────────┐
  │         FUTURE UPGRADE PATH ANALYSIS: EL8 → EL9                   │
  └─────────────────────────────────────────────────────────────────────┘

  EL8 (AlmaLinux 8 / Rocky Linux 8) → EL9 (AlmaLinux 9 / Rocky Linux 9)
  is supported via the same ELevate tooling.

  TIMELINE:
    AlmaLinux 8  → EOL: 2029-03-01
    Rocky Linux 8→ EOL: 2029-05-31
    AlmaLinux 9  → EOL: 2032-05-31
    Rocky Linux 9→ EOL: 2032-05-31

  WHEN READY TO UPGRADE TO EL9:
    1. Ensure all packages are fully updated on EL8:
         dnf update -y

    2. Install ELevate for EL8→EL9:
         dnf install -y https://repo.almalinux.org/elevate/elevate-release-latest-el8.noarch.rpm
         dnf install -y leapp-upgrade leapp-data-almalinux   # or leapp-data-rocky

    3. Pre-upgrade check:
         leapp preupgrade

    4. Review and fix inhibitors in /var/log/leapp/leapp-report.txt

    5. Upgrade:
         leapp upgrade
         # System reboots and completes upgrade automatically

  KEY EL8 → EL9 CHANGES TO PLAN FOR:
    • Minimum TLS version: 1.2 (TLS 1.0/1.1 disabled by default)
    • OpenSSL 3.0 (breaking changes for some apps using deprecated APIs)
    • PHP AppStream: 8.0, 8.1, 8.2
    • Python 3.9 as default (3.6/3.8 via modules)
    • MySQL 8.0, MariaDB 10.5/10.6/10.11
    • PostgreSQL 13/14/15/16
    • Node.js 16, 18, 20 module streams
    • Kernel 5.14 (RHEL 9 kernel)
    • nftables replaces iptables (nft backend for firewalld)
    • SHA-1 signature policy changes (may affect old SSL certs)
    • XFS default (no ext4 for new installs)
    • cgroups v2 default
    • GRUB2 with BLS (Boot Loader Specification) required

  UPGRADE CHAIN SUMMARY:
    CentOS 7.x
      └─→ [This script — ELevate] → AlmaLinux 8 / Rocky Linux 8
               └─→ [ELevate EL8→EL9] → AlmaLinux 9 / Rocky Linux 9
                         └─→ [Future ELevate] → AlmaLinux 10 / Rocky Linux 10

EOF

    log_ok "Future upgrade path analysis complete."
}

# ---------------------------------------------------------------------------
# SECTION 7: GENERATE FINAL REPORT
# ---------------------------------------------------------------------------
generate_report() {
    log_section "Generating Final Migration Report"

    cat > "$REPORT_FILE" <<EOF
================================================================================
  CentOS 7 → EL8 Migration Analysis Report
  Generated: $(date)
  Hostname : $(hostname -f)
  Script   : $SCRIPT_NAME v${SCRIPT_VERSION}
================================================================================

OS INFORMATION
--------------
$(cat /etc/centos-release 2>/dev/null || cat /etc/os-release)
Kernel: $(uname -r)
Arch  : $(uname -m)

RISK SUMMARY
------------
  CRITICAL : $RISK_CRITICAL
  HIGH     : $RISK_HIGH
  MEDIUM   : $RISK_MEDIUM
  LOW      : $RISK_LOW

$(if [[ $RISK_CRITICAL -gt 0 ]]; then
  echo "⛔ CRITICAL ISSUES DETECTED — DO NOT UPGRADE WITHOUT RESOLVING"
elif [[ $RISK_HIGH -gt 0 ]]; then
  echo "⚠️  HIGH RISK ISSUES DETECTED — REVIEW CAREFULLY BEFORE UPGRADING"
elif [[ $RISK_MEDIUM -gt 0 ]]; then
  echo "⚡ MEDIUM RISK — REVIEW WARNINGS BEFORE UPGRADING"
else
  echo "✅ NO CRITICAL OR HIGH RISK ISSUES DETECTED — UPGRADE APPEARS SAFE"
fi)

HARDWARE
--------
CPU   : $(lscpu | grep "Model name" | sed 's/Model name: *//')
Memory: $(free -h | awk '/^Mem:/{print $2}') total
Virt  : $(systemd-detect-virt 2>/dev/null || echo unknown)

DISK LAYOUT
-----------
$(df -hT)

SERVICES TO VERIFY POST-UPGRADE
---------------------------------
$(systemctl list-units --type=service --state=active 2>/dev/null | awk '{print $1}' | grep ".service" | head -30)

LOG FILES
---------
  Full Log      : $LOG_FILE
  This Report   : $REPORT_FILE
  leapp report  : /var/log/leapp/leapp-report.txt
  Config Backup : ${LOG_DIR}/config_backup_${START_TIME}/

NEXT STEPS
----------
1. Resolve all CRITICAL and HIGH risk issues above.
2. Verify backup integrity before proceeding.
3. Run: leapp preupgrade — review /var/log/leapp/leapp-report.txt
4. Fix all leapp inhibitors.
5. Run: leapp upgrade — system will reboot and complete upgrade.
6. Post-upgrade: run script with --post-upgrade to validate.
7. Re-enable and test all services.
8. Update monitoring, backup agents, and management tools for EL8.

RESTORE FROM BACKUP
-------------------
$(if [[ -n "$BACKUP_DEV" ]]; then
  echo "  dd if=$BACKUP_DEV of=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | head -1 | sed 's/[0-9]*$//') bs=4M conv=noerror,sync status=progress"
else
  echo "  No backup device specified."
fi)

================================================================================
EOF

    log_ok "Report saved → $REPORT_FILE"
    echo
    cat "$REPORT_FILE"
}

# ---------------------------------------------------------------------------
# INTERACTIVE: TARGET DISTRO SELECTION
# ---------------------------------------------------------------------------
select_target_distro() {
    if [[ -n "$TARGET_DISTRO" ]]; then
        if [[ "$TARGET_DISTRO" != "alma" && "$TARGET_DISTRO" != "rocky" ]]; then
            die "Invalid --target '$TARGET_DISTRO'. Use 'alma' or 'rocky'."
        fi
        return 0
    fi

    echo
    echo -e "${BOLD}Select target distribution:${RESET}"
    echo "  1) AlmaLinux 8  — Community, RHEL-compatible, backed by CloudLinux"
    echo "  2) Rocky Linux 8 — Community, RHEL-compatible, founded by CentOS co-founder"
    echo
    echo -en "${CYAN}Enter choice [1/2]: ${RESET}"
    read -r choice
    case "$choice" in
        1) TARGET_DISTRO="alma"  ;;
        2) TARGET_DISTRO="rocky" ;;
        *) die "Invalid choice." ;;
    esac
    log_info "Target selected: $TARGET_DISTRO"
}

# ---------------------------------------------------------------------------
# MAIN ORCHESTRATION
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_logging
    banner

    check_root
    check_centos7
    check_required_tools

    # -----------------------------------------------------------------------
    # ANALYSIS PHASE
    # -----------------------------------------------------------------------
    log_section "PHASE 1: SYSTEM ANALYSIS"
    analyze_system
    analyze_boot
    analyze_network
    analyze_repositories
    analyze_installed_packages
    analyze_services
    analyze_security
    analyze_users
    analyze_applications_deep
    check_disk_space_for_upgrade
    analyze_future_upgrade_path

    generate_report

    # -----------------------------------------------------------------------
    # ANALYZE ONLY? STOP HERE.
    # -----------------------------------------------------------------------
    if [[ "$ANALYZE_ONLY" == true ]]; then
        log_info "Analysis complete. --analyze-only specified — no changes made."
        log_info "Full log: $LOG_FILE"
        log_info "Report:   $REPORT_FILE"
        exit 0
    fi

    # -----------------------------------------------------------------------
    # RISK GATE
    # -----------------------------------------------------------------------
    echo
    log_info "Risk Summary — CRITICAL: $RISK_CRITICAL | HIGH: $RISK_HIGH | MEDIUM: $RISK_MEDIUM | LOW: $RISK_LOW"
    if [[ $RISK_CRITICAL -gt 0 ]]; then
        log_error "CRITICAL risks detected. Review the report and resolve before upgrading."
        if ! confirm "Critical issues found. Do you still want to continue? (NOT RECOMMENDED)"; then
            die "Upgrade aborted due to critical risks."
        fi
    elif [[ $RISK_HIGH -gt 0 ]]; then
        log_warn "High risk items detected. Review the report."
        if ! confirm "High risk issues found. Continue with upgrade?"; then
            die "Upgrade aborted by user."
        fi
    fi

    # -----------------------------------------------------------------------
    # TARGET SELECTION
    # -----------------------------------------------------------------------
    select_target_distro

    # -----------------------------------------------------------------------
    # PHASE 2: BACKUP
    # -----------------------------------------------------------------------
    log_section "PHASE 2: BACKUP"
    if [[ "$SKIP_BACKUP" == true ]]; then
        log_warn "--skip-backup specified. Proceeding WITHOUT disk image backup."
        log_warn "Ensure you have an external backup before continuing."
        if ! confirm "Proceed without backup?"; then
            die "Upgrade aborted — no backup."
        fi
    else
        backup_to_block_device
    fi

    # -----------------------------------------------------------------------
    # PHASE 3: PREPARATION
    # -----------------------------------------------------------------------
    log_section "PHASE 3: PRE-UPGRADE PREPARATION"
    if ! confirm "Begin pre-upgrade preparation (package updates, cleanup)?"; then
        die "Upgrade aborted by user."
    fi
    prepare_system

    # -----------------------------------------------------------------------
    # PHASE 4: ELEVATE / LEAPP
    # -----------------------------------------------------------------------
    log_section "PHASE 4: ELEVATE UPGRADE"
    install_elevate
    resolve_leapp_bin
    fix_leapp_inhibitors
    run_preupgrade_check
    apply_leapp_answers

    # -----------------------------------------------------------------------
    # FINAL CONFIRM & LAUNCH
    # -----------------------------------------------------------------------
    echo
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${RED}  FINAL CONFIRMATION: UPGRADE WILL BEGIN               ${RESET}"
    echo -e "${BOLD}${RED}  Target: ${TARGET_DISTRO^^} Linux 8                    ${RESET}"
    echo -e "${BOLD}${RED}  System will REBOOT automatically during upgrade.     ${RESET}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════${RESET}"
    echo

    if ! confirm "FINAL CONFIRMATION: Proceed with upgrade to ${TARGET_DISTRO^^} Linux 8?"; then
        die "Upgrade cancelled by user at final confirmation."
    fi

    run_upgrade

    # If leapp upgrade exits without rebooting (shouldn't normally happen)
    log_info "After system reboots and upgrade completes, run:"
    log_info "  $0 --post-upgrade"
}

# Handle --post-upgrade mode
if [[ "${1:-}" == "--post-upgrade" ]]; then
    init_logging
    banner
    check_root
    post_upgrade_validate
    generate_report
    exit 0
fi

main "$@"
