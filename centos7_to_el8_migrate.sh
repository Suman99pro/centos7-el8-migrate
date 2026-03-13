#!/usr/bin/env bash
# =============================================================================
#  CentOS 7 → AlmaLinux 8 / Rocky Linux 8  ·  Migration Toolkit  v3.0.0
# =============================================================================
#  Modular, menu-driven, non-destructive assessment → fix → migrate workflow.
#
#  USAGE:
#    sudo ./centos7_to_el8_migrate.sh [OPTIONS]
#
#  OPTIONS:
#    --assess          Run preflight assessment only (no changes)
#    --fix             Auto-fix safe issues found during assessment
#    --migrate         Full interactive migration
#    --post-upgrade    Post-reboot validation
#    --target alma|rocky   Pre-select target distro
#    --backup-dev /dev/sdX Block device for disk backup
#    --skip-backup     Skip backup phase (DANGEROUS)
#    --auto-yes        Non-interactive mode (CI/testing only)
#    --log-dir /path   Custom log dir (default: /var/log/el8-migration)
#    --help            Show this help
# =============================================================================

# ---------------------------------------------------------------------------
# SHELL OPTIONS — deliberately NO set -e; errors are handled explicitly
# ---------------------------------------------------------------------------
set -uo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# VERSION & CONSTANTS
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly START_TIME="$(date +%Y%m%d_%H%M%S)"

# ---------------------------------------------------------------------------
# DEFAULTS
# ---------------------------------------------------------------------------
LOG_DIR="/var/log/el8-migration"
LOG_FILE=""
REPORT_FILE=""
TARGET_DISTRO=""
BACKUP_DEV=""
SKIP_BACKUP=false
AUTO_YES=false
MODE=""

# ---------------------------------------------------------------------------
# RUNTIME STATE
# ---------------------------------------------------------------------------
LEAPP_BIN=""
STATE_FILE=""

# Preflight finding arrays — declare explicitly for bash 4.2 (CentOS 7) set -u compatibility
declare -a PREFLIGHT_BLOCKS=()
declare -a PREFLIGHT_WARNS=()
declare -a PREFLIGHT_AUTOS=()
declare -a PREFLIGHT_INFO=()
declare -a PREFLIGHT_PASS=()

# ---------------------------------------------------------------------------
# COLOURS
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'

# ===========================================================================
#  LOGGING & HELPERS
# ===========================================================================

init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/migration_${START_TIME}.log"
    REPORT_FILE="${LOG_DIR}/preflight_report_${START_TIME}.txt"
    STATE_FILE="${LOG_DIR}/.migration_state"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Log: $LOG_FILE"
}

_ts()      { date '+%Y-%m-%d %H:%M:%S'; }
log()      { echo -e "[$(_ts)] $*"; }
log_info() { log "${GREEN}[INFO]${RESET}   $*"; }
log_ok()   { log "${GREEN}[OK]${RESET}     $*"; }
log_warn() { log "${YELLOW}[WARN]${RESET}   $*"; }
log_error(){ log "${RED}[ERROR]${RESET}  $*"; }
log_section() {
    echo
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
}

# Preflight collectors — never exit, just record
pf_block() { PREFLIGHT_BLOCKS+=("$*"); log "${RED}${BOLD}[BLOCK]${RESET}    $*"; }
pf_warn()  { PREFLIGHT_WARNS+=("$*");  log "${YELLOW}[WARN]${RESET}     $*"; }
pf_auto()  { PREFLIGHT_AUTOS+=("$*");  log "${MAGENTA}[AUTO-FIX]${RESET} $*"; }
pf_info()  { PREFLIGHT_INFO+=("$*");   log "${BLUE}[INFO]${RESET}     $*"; }
pf_pass()  { PREFLIGHT_PASS+=("$*");   log "${GREEN}[PASS]${RESET}     $*"; }

# Hard exit — only for situations truly unrecoverable (no root, etc.)
die() { log_error "FATAL: $*"; exit 1; }

confirm() {
    local msg="$1"
    [[ "$AUTO_YES" == true ]] && { log_info "Auto-yes: $msg"; return 0; }
    echo -en "\n${YELLOW}  ▶ ${msg} [y/N]: ${RESET}"
    local ans; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# State persistence
state_set() { grep -v "^${1}=" "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.tmp" || true; mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true; echo "${1}=${2}" >> "$STATE_FILE"; }
state_get() { grep "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || echo ""; }
state_init(){ mkdir -p "$LOG_DIR"; touch "${LOG_DIR}/.migration_state"; STATE_FILE="${LOG_DIR}/.migration_state"; }

banner() {
    clear 2>/dev/null || true
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ██████╗███████╗███╗   ██╗████████╗ ██████╗ ███████╗    ███████╗██╗
 ██╔════╝██╔════╝████╗  ██║╚══██╔══╝██╔═══██╗██╔════╝    ██╔════╝██║
 ██║     █████╗  ██╔██╗ ██║   ██║   ██║   ██║███████╗    █████╗  ██║
 ██║     ██╔══╝  ██║╚██╗██║   ██║   ██║   ██║╚════██║    ██╔══╝  ██║
 ╚██████╗███████╗██║ ╚████║   ██║   ╚██████╔╝███████║    ███████╗███████╗
  ╚═════╝╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚══════╝    ╚══════╝╚══════╝
       CentOS 7  →  AlmaLinux 8 / Rocky Linux 8  Migration Toolkit
BANNER
    echo -e "${RESET}"
    echo -e "  ${WHITE}Version:${RESET} ${SCRIPT_VERSION}   ${WHITE}Date:${RESET} $(date '+%Y-%m-%d %H:%M')   ${WHITE}Host:${RESET} $(hostname -f 2>/dev/null || hostname)"
    echo
}

usage() {
    cat <<EOF
Usage: sudo $SCRIPT_NAME [OPTIONS]

Modes (or run with no flags for interactive menu):
  --assess            Preflight assessment — zero changes made
  --fix               Auto-fix safe issues found by assess
  --migrate           Full interactive migration wizard
  --post-upgrade      Post-reboot validation

Options:
  --target alma|rocky   Pre-select target distribution
  --backup-dev /dev/sdX Block device for full disk image backup
  --skip-backup         Skip backup (NOT recommended in production)
  --auto-yes            Non-interactive mode
  --log-dir /path       Log directory (default: /var/log/el8-migration)
  -h, --help            Show this help

Examples:
  sudo $SCRIPT_NAME --assess
  sudo $SCRIPT_NAME --fix
  sudo $SCRIPT_NAME --migrate --target alma --backup-dev /dev/sdb
  sudo $SCRIPT_NAME --post-upgrade
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --assess)       MODE="assess"; shift ;;
            --fix)          MODE="fix"; shift ;;
            --migrate)      MODE="migrate"; shift ;;
            --post-upgrade) MODE="post-upgrade"; shift ;;
            --target)       TARGET_DISTRO="${2,,}"; shift 2 ;;
            --backup-dev)   BACKUP_DEV="$2"; shift 2 ;;
            --skip-backup)  SKIP_BACKUP=true; shift ;;
            --auto-yes)     AUTO_YES=true; shift ;;
            --log-dir)      LOG_DIR="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *) echo "Unknown option: $1  (use --help)"; exit 1 ;;
        esac
    done
}

# ===========================================================================
#  SECTION 1 — PREFLIGHT ASSESSMENT  (read-only, never exits on error)
# ===========================================================================

preflight_reset() {
    PREFLIGHT_BLOCKS=(); PREFLIGHT_WARNS=()
    PREFLIGHT_AUTOS=();  PREFLIGHT_INFO=(); PREFLIGHT_PASS=()
    # Bash 4.2 (CentOS 7) treats empty arrays as unbound under set -u
    # Re-declare explicitly to avoid "unbound variable" errors
    declare -ga PREFLIGHT_BLOCKS PREFLIGHT_WARNS PREFLIGHT_AUTOS PREFLIGHT_INFO PREFLIGHT_PASS
}

# --- individual checks -------------------------------------------------------

_pf_root() {
    if [[ $EUID -ne 0 ]]; then
        pf_block "Must run as root. Re-run with: sudo $SCRIPT_NAME"
    else
        pf_pass "Running as root."
    fi
}

_pf_os() {
    if [[ ! -f /etc/centos-release ]]; then
        pf_block "Not a CentOS system (/etc/centos-release missing)."
        return
    fi
    local ver
    ver=$(rpm -q --queryformat '%{VERSION}' centos-release 2>/dev/null || echo "")
    if [[ "$ver" != "7" ]]; then
        pf_block "CentOS version '$ver' detected. Only CentOS 7.x is supported."
    else
        pf_pass "OS: $(cat /etc/centos-release)"
    fi
}

_pf_disk() {
    local root_avail boot_avail var_avail
    root_avail=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -d 'G ' || echo "0")
    boot_avail=$(df --output=avail -BG /boot 2>/dev/null | tail -1 | tr -d 'G ' || echo "0")
    var_avail=$(df --output=avail -BG /var 2>/dev/null | tail -1 | tr -d 'G ' || echo "0")

    if [[ "$root_avail" -lt 10 ]]; then
        pf_block "/ has only ${root_avail}G free. ELevate requires ≥10G. Run: yum clean all; package-cleanup --oldkernels"
    else
        pf_pass "/ disk: ${root_avail}G free (≥10G required)."
    fi

    if [[ "$boot_avail" -lt 1 ]]; then
        pf_block "/boot has only ${boot_avail}G free. Need ≥1G. Run: package-cleanup --oldkernels --count=1"
    else
        pf_pass "/boot disk: ${boot_avail}G free."
    fi

    if [[ "$var_avail" -lt 3 ]]; then
        pf_warn "/var has only ${var_avail}G free. leapp scratch needs ≥3G in /var. Free space before migrating."
    else
        pf_pass "/var disk: ${var_avail}G free."
    fi
}

_pf_network() {
    if curl -4 --silent --max-time 10 --head "https://repo.almalinux.org" &>/dev/null; then
        pf_pass "Network: repo.almalinux.org reachable (IPv4)."
    else
        pf_block "Cannot reach repo.almalinux.org via IPv4. Internet required for ELevate packages and repo sync."
    fi

    local ipv6_disabled
    ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    if [[ "$ipv6_disabled" == "0" ]]; then
        if ! ping6 -c 1 -W 3 2620:fe::fe &>/dev/null 2>&1; then
            pf_auto "IPv6 enabled but not working. Will be disabled — broken IPv6 causes leapp nspawn repo failures."
        else
            pf_pass "IPv6: working."
        fi
    else
        pf_pass "IPv6: already disabled (safe for leapp)."
    fi

    # Check if a leapp nspawn overlay exists and has a broken resolv.conf
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    if [[ -n "$overlay" ]]; then
        local overlay_resolv="${overlay}/etc/resolv.conf"
        if [[ ! -s "$overlay_resolv" ]]; then
            pf_auto "leapp nspawn overlay exists but has empty/missing resolv.conf ($overlay_resolv). Will be fixed — this causes all repo syncs to fail inside the container."
        else
            pf_pass "leapp nspawn overlay resolv.conf present."
        fi
    fi
}

_pf_tools() {
    local missing=()
    for t in rpm yum curl lsblk df free uname ss ip awk grep sed; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        pf_auto "Missing tools: ${missing[*]}. Will install automatically."
    else
        pf_pass "All required CLI tools present."
    fi
}

_pf_boot() {
    if [[ -d /sys/firmware/efi ]]; then
        pf_info "Boot: UEFI. leapp handles EFI grub2 update automatically."
    else
        pf_info "Boot: BIOS/Legacy. leapp runs grub2-install automatically."
    fi

    if grep -q "active" /proc/mdstat 2>/dev/null; then
        if grep -q "_" /proc/mdstat 2>/dev/null; then
            pf_block "Software RAID appears degraded (/proc/mdstat contains '_'). Repair before upgrading."
        else
            pf_warn "Software RAID detected. Verify all arrays healthy: cat /proc/mdstat"
        fi
    fi

    local kcount
    kcount=$(rpm -q kernel 2>/dev/null | wc -l || echo "0")
    if [[ "$kcount" -gt 2 ]]; then
        pf_auto "$kcount kernel packages installed. Old kernels will be removed to free /boot space."
    else
        pf_pass "Kernel count: $kcount."
    fi
}

_pf_packages() {
    local pkg_count
    pkg_count=$(rpm -qa 2>/dev/null | wc -l || echo "0")
    pf_info "Total installed packages: $pkg_count."

    # ABRT
    local abrt
    abrt=$(rpm -qa 2>/dev/null | grep "^abrt" || true)
    if [[ -n "$abrt" ]]; then
        pf_auto "ABRT packages detected. These conflict with leapp and will be removed safely."
    else
        pf_pass "No ABRT packages."
    fi

    # SCL
    if rpm -q centos-release-scl &>/dev/null 2>&1 || rpm -q scl-utils &>/dev/null 2>&1; then
        pf_warn "Software Collections (SCL) detected. SCL is NOT available in EL8. Migrate SCL apps to AppStream module streams."
    fi

    # PHP
    local php
    php=$(php -v 2>/dev/null | head -1 | grep -oE "PHP [0-9]+\.[0-9]+" || echo "")
    if [[ -n "$php" ]]; then
        if echo "$php" | grep -qE "PHP (5\.|7\.[01])"; then
            pf_warn "EOL PHP detected: $php. Not in EL8 default repos. Plan migration to PHP 7.4+ or 8.x."
        else
            pf_info "PHP detected: $php. Verify EL8 AppStream/Remi availability."
        fi
    fi

    # MySQL
    if rpm -q mysql-server &>/dev/null 2>&1; then
        pf_warn "MySQL Server detected. MySQL 5.x not in EL8 repos. Plan migration to MySQL 8.0 or MariaDB 10.x."
    fi

    # MariaDB
    if rpm -q mariadb-server &>/dev/null 2>&1; then
        pf_info "MariaDB detected. EL8 ships MariaDB 10.3+. Verify data compatibility."
    fi

    # PostgreSQL
    if rpm -q postgresql-server &>/dev/null 2>&1; then
        pf_info "PostgreSQL detected. Use PostgreSQL official EL8 repo post-upgrade."
    fi

    # Kubernetes
    if command -v kubectl &>/dev/null 2>&1 || command -v kubelet &>/dev/null 2>&1; then
        pf_warn "Kubernetes detected. Upgrade k8s AFTER OS upgrade using EL8 k8s repos."
    fi

    # Custom kernel modules
    local extra_dir="/lib/modules/$(uname -r)/extra"
    if [[ -d "$extra_dir" ]] && find "$extra_dir" -name "*.ko" 2>/dev/null | grep -q .; then
        pf_warn "Custom out-of-tree kernel modules found in $extra_dir. They will NOT work after kernel upgrade."
    else
        pf_pass "No custom out-of-tree kernel modules."
    fi

    # SSSD
    if rpm -q sssd &>/dev/null 2>&1; then
        pf_info "SSSD detected (LDAP/AD/FreeIPA auth). Verify sssd config post-upgrade."
    fi
}

_pf_repos() {
    local tp=()
    while IFS= read -r rf; do
        local rn; rn=$(basename "$rf" .repo)
        echo "$rn" | grep -qiE "^(CentOS|base|updates|extras|epel|centos)" || tp+=("$rn")
    done < <(find /etc/yum.repos.d/ -name "*.repo" 2>/dev/null)

    if [[ ${#tp[@]} -gt 0 ]]; then
        pf_warn "Third-party repos: ${tp[*]+"${tp[*]}"}. Will be temporarily disabled during upgrade."
    else
        pf_pass "No third-party repos detected."
    fi

    for r in percona mariadb mysql nginx elastic remi ius webtatic; do
        find /etc/yum.repos.d/ -name "*.repo" -exec grep -li "$r" {} \; 2>/dev/null | grep -q . && \
            pf_warn "Repo '$r' found. Verify EL8-compatible version exists."
    done
}

_pf_security() {
    local sel; sel=$(getenforce 2>/dev/null || echo "disabled")
    pf_info "SELinux: $sel. leapp sets permissive during upgrade — re-enable enforcing post-upgrade."

    if command -v cryptsetup &>/dev/null 2>&1 && cryptsetup status 2>/dev/null | grep -q "active"; then
        pf_warn "LUKS encryption detected. Ensure backup captures encrypted partition headers."
    fi

    local sp; sp=$(grep -i "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    pf_info "SSH port: ${sp:-22}. Verify firewall allows access post-upgrade."
}

_pf_services() {
    local det=()
    for s in sshd httpd nginx mysql mariadb postgresql redis mongod; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service" && \
            det+=("${s}:$(systemctl is-active "$s" 2>/dev/null || echo inactive)")
    done
    if [[ ${#det[@]} -gt 0 ]]; then
        pf_info "Critical services detected: ${det[*]+"${det[*]}"}. Verify each restarts correctly post-upgrade."
    else
        pf_pass "No critical application services detected."
    fi
}

_pf_virt() {
    local v; v=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    pf_info "Virtualisation: $v"
    [[ "$v" == "none" ]] && pf_info "Bare metal: ensure out-of-band console access (iDRAC/iLO) before upgrade."
}

# --- master runner ------------------------------------------------------------
run_preflight() {
    log_section "PREFLIGHT ASSESSMENT"
    preflight_reset
    _pf_root; _pf_os; _pf_disk; _pf_network; _pf_tools
    _pf_boot; _pf_packages; _pf_repos; _pf_security; _pf_services; _pf_virt
}

# --- report printer ----------------------------------------------------------
print_preflight_report() {
    echo
    echo -e "${BOLD}${WHITE}╔══════════════════════════════════════════════════════════════╗${RESET}"
    printf "${BOLD}${WHITE}║  PREFLIGHT REPORT  %-44s║${RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "${BOLD}${WHITE}║  Host: %-54s║${RESET}\n" "$(hostname -f 2>/dev/null || hostname)"
    echo -e "${BOLD}${WHITE}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo

    if [[ ${#PREFLIGHT_PASS[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}✔  PASSED (${#PREFLIGHT_PASS[@]})${RESET}"
        for i in "${PREFLIGHT_PASS[@]+"${PREFLIGHT_PASS[@]}"}"; do echo -e "   ${GREEN}✔${RESET} $i"; done; echo
    fi

    if [[ ${#PREFLIGHT_INFO[@]} -gt 0 ]]; then
        echo -e "${BLUE}${BOLD}ℹ  INFORMATIONAL (${#PREFLIGHT_INFO[@]})${RESET}"
        for i in "${PREFLIGHT_INFO[@]+"${PREFLIGHT_INFO[@]}"}"; do echo -e "   ${BLUE}ℹ${RESET} $i"; done; echo
    fi

    if [[ ${#PREFLIGHT_AUTOS[@]} -gt 0 ]]; then
        echo -e "${MAGENTA}${BOLD}⚙  AUTO-FIXABLE (${#PREFLIGHT_AUTOS[@]}) — will be fixed automatically${RESET}"
        for i in "${PREFLIGHT_AUTOS[@]+"${PREFLIGHT_AUTOS[@]}"}"; do echo -e "   ${MAGENTA}⚙${RESET} $i"; done; echo
    fi

    if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}${BOLD}⚠  WARNINGS — review before proceeding (${#PREFLIGHT_WARNS[@]})${RESET}"
        for i in "${PREFLIGHT_WARNS[@]+"${PREFLIGHT_WARNS[@]}"}"; do echo -e "   ${YELLOW}⚠${RESET} $i"; done; echo
    fi

    if [[ ${#PREFLIGHT_BLOCKS[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}✖  BLOCKERS — MUST FIX BEFORE MIGRATION (${#PREFLIGHT_BLOCKS[@]})${RESET}"
        for i in "${PREFLIGHT_BLOCKS[@]+"${PREFLIGHT_BLOCKS[@]}"}"; do echo -e "   ${RED}✖${RESET} $i"; done; echo
    fi

    echo -e "${BOLD}${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    if [[ ${#PREFLIGHT_BLOCKS[@]} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}VERDICT: ✖  NOT READY — Fix ${#PREFLIGHT_BLOCKS[@]} blocker(s) first.${RESET}"
    elif [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}VERDICT: ⚠  PROCEED WITH CAUTION — ${#PREFLIGHT_WARNS[@]} warning(s) to review.${RESET}"
    else
        echo -e "  ${GREEN}${BOLD}VERDICT: ✔  GO — System is ready for migration.${RESET}"
    fi
    echo -e "${BOLD}${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo

    # Save to file
    {
        echo "PREFLIGHT REPORT — $(date)"
        echo "Host: $(hostname -f 2>/dev/null || hostname) | Script: v$SCRIPT_VERSION"
        echo "════════════════════════════════════════════"
        echo; echo "PASSED (${#PREFLIGHT_PASS[@]}):"
        for i in "${PREFLIGHT_PASS[@]+"${PREFLIGHT_PASS[@]}"}"; do echo "  [PASS]  $i"; done
        echo; echo "INFORMATIONAL:"
        for i in "${PREFLIGHT_INFO[@]+"${PREFLIGHT_INFO[@]}"}"; do echo "  [INFO]  $i"; done
        echo; echo "AUTO-FIXABLE:"
        for i in "${PREFLIGHT_AUTOS[@]+"${PREFLIGHT_AUTOS[@]}"}"; do echo "  [AUTO]  $i"; done
        echo; echo "WARNINGS:"
        for i in "${PREFLIGHT_WARNS[@]+"${PREFLIGHT_WARNS[@]}"}"; do echo "  [WARN]  $i"; done
        echo; echo "BLOCKERS:"
        for i in "${PREFLIGHT_BLOCKS[@]+"${PREFLIGHT_BLOCKS[@]}"}"; do echo "  [BLOCK] $i"; done
        echo
        if [[ ${#PREFLIGHT_BLOCKS[@]} -gt 0 ]]; then echo "VERDICT: NOT READY"
        elif [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then echo "VERDICT: PROCEED WITH CAUTION"
        else echo "VERDICT: GO"; fi
    } > "$REPORT_FILE"

    log_info "Report: $REPORT_FILE"
}

# ===========================================================================
#  SECTION 2 — AUTO-FIX
# ===========================================================================

run_autofix() {
    log_section "AUTO-FIX: Applying Safe Remediations"

    # IPv6 — disable if broken
    local ipv6_off
    ipv6_off=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    if [[ "$ipv6_off" == "0" ]] && ! ping6 -c 1 -W 3 2620:fe::fe &>/dev/null 2>&1; then
        log_info "Disabling broken IPv6..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null || true
        grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null || \
            printf '\n# el8-migration: IPv6 disabled\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' >> /etc/sysctl.conf
        log_ok "IPv6 disabled."
    fi

    # Old kernels
    local kcount; kcount=$(rpm -q kernel 2>/dev/null | wc -l || echo "0")
    if [[ "$kcount" -gt 2 ]]; then
        log_info "Removing old kernels..."
        package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
        log_ok "Old kernels removed."
    fi

    # ABRT
    local abrt; abrt=$(rpm -qa 2>/dev/null | grep "^abrt" || true)
    if [[ -n "$abrt" ]]; then
        log_info "Removing ABRT packages (safe, no cascade)..."
        echo "$abrt" | xargs yum remove -y \
            --setopt=clean_requirements_on_remove=0 2>/dev/null || true
        log_ok "ABRT removed."
    fi

    # Missing tools
    local miss=()
    for t in rpm yum curl lsblk df free uname ss ip awk grep sed; do
        command -v "$t" &>/dev/null || miss+=("$t")
    done
    if [[ ${#miss[@]} -gt 0 ]]; then
        log_info "Installing missing tools: ${miss[*]+${miss[*]}}"
        yum install -y "${miss[@]+"${miss[@]}"}" 2>/dev/null || log_warn "Some tools could not install."
    fi

    # redhat-release symlink
    if [[ ! -f /etc/redhat-release ]] && [[ -f /etc/centos-release ]]; then
        ln -sf /etc/centos-release /etc/redhat-release 2>/dev/null || true
        log_ok "Fixed /etc/redhat-release symlink."
    fi

    # nspawn overlay resolv.conf — fix if overlay already exists from a previous run
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    if [[ -n "$overlay" ]]; then
        local overlay_resolv="${overlay}/etc/resolv.conf"
        if [[ ! -s "$overlay_resolv" ]]; then
            log_info "Fixing leapp nspawn overlay resolv.conf..."
            mkdir -p "${overlay}/etc" 2>/dev/null || true
            cp -f /etc/resolv.conf "$overlay_resolv" 2>/dev/null || true
            log_ok "nspawn overlay resolv.conf fixed."
        fi
    fi

    log_ok "Auto-fix complete. Re-run --assess to verify."
}

# ===========================================================================
#  SECTION 3 — MIGRATION PHASES
# ===========================================================================

# ---------------------------------------------------------------------------
# Phase 1: Select target distro
# ---------------------------------------------------------------------------
phase_select_target() {
    log_section "Phase 1/6: Select Target Distribution"

    if [[ -n "$TARGET_DISTRO" ]]; then
        [[ "$TARGET_DISTRO" == "alma" || "$TARGET_DISTRO" == "rocky" ]] || \
            die "Invalid --target '$TARGET_DISTRO'. Use 'alma' or 'rocky'."
        log_ok "Target: $TARGET_DISTRO (from command line)"
        state_set "TARGET_DISTRO" "$TARGET_DISTRO"; return 0
    fi

    local saved; saved=$(state_get "TARGET_DISTRO")
    if [[ -n "$saved" ]]; then
        echo -e "\n  Previously selected: ${BOLD}${saved^^} Linux 8${RESET}"
        if confirm "Use $saved?"; then
            TARGET_DISTRO="$saved"; log_ok "Target: $TARGET_DISTRO (restored)"; return 0
        fi
    fi

    echo
    echo -e "  ${BOLD}Select target distribution:${RESET}"
    echo -e "  ${CYAN}1)${RESET} AlmaLinux 8  — backed by CloudLinux.  EOL: 2029-03-01"
    echo -e "  ${CYAN}2)${RESET} Rocky Linux 8 — founded by CentOS co-founder.  EOL: 2029-05-31"
    echo
    echo -en "  ${YELLOW}Choice [1/2]: ${RESET}"
    local ch; read -r ch
    case "$ch" in
        1) TARGET_DISTRO="alma" ;;
        2) TARGET_DISTRO="rocky" ;;
        *) die "Invalid choice." ;;
    esac

    log_ok "Target: ${TARGET_DISTRO^^} Linux 8"
    state_set "TARGET_DISTRO" "$TARGET_DISTRO"
}

# ---------------------------------------------------------------------------
# Phase 2: Backup
# ---------------------------------------------------------------------------
phase_backup() {
    log_section "Phase 2/6: Disk Image Backup"

    if [[ "$(state_get PHASE_BACKUP)" == "complete" ]]; then
        log_ok "Backup already completed — skipping."; return 0
    fi

    if [[ "$SKIP_BACKUP" == true ]]; then
        log_warn "--skip-backup: proceeding without backup."
        confirm "Confirm: proceed WITHOUT backup?" || die "Migration aborted — backup required."
        state_set "PHASE_BACKUP" "skipped"; return 0
    fi

    if [[ -z "$BACKUP_DEV" ]]; then
        echo
        echo -e "  ${YELLOW}No backup device specified.${RESET}"
        echo -e "  Enter block device path (e.g. /dev/sdb), or 's' to skip:"
        echo -en "  ${YELLOW}Device: ${RESET}"
        local inp; read -r inp
        if [[ "$inp" == "s" ]]; then
            confirm "Skip backup — you accept all risk?" || die "Aborted."
            state_set "PHASE_BACKUP" "skipped"; return 0
        fi
        BACKUP_DEV="$inp"; state_set "BACKUP_DEV" "$BACKUP_DEV"
    fi

    [[ -b "$BACKUP_DEV" ]] || die "Not a block device: $BACKUP_DEV"

    local root_dev source_disk
    root_dev=$(df / | tail -1 | awk '{print $1}')
    if echo "$root_dev" | grep -q "mapper"; then
        source_disk=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | head -1 | sed 's/[0-9]*$//')
    else
        source_disk=$(echo "$root_dev" | sed 's/[0-9]*$//')
    fi

    local ss ds
    ss=$(lsblk -bno SIZE "$source_disk" 2>/dev/null | head -1 || echo "0")
    ds=$(lsblk -bno SIZE "$BACKUP_DEV"  2>/dev/null | head -1 || echo "0")

    log_info "Source: $source_disk ($(numfmt --to=iec "$ss" 2>/dev/null || echo "${ss}B"))"
    log_info "Target: $BACKUP_DEV ($(numfmt --to=iec "$ds" 2>/dev/null || echo "${ds}B"))"
    [[ "$ds" -ge "$ss" ]] || die "Backup device is smaller than source disk."

    echo; log_warn "This will OVERWRITE ALL DATA on $BACKUP_DEV."
    confirm "Proceed with disk backup? (ERASES $BACKUP_DEV)" || die "Backup declined."

    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    log_info "Starting backup..."
    local t0; t0=$(date +%s)
    if command -v pv &>/dev/null; then
        pv -tpreb "$source_disk" | dd of="$BACKUP_DEV" bs=4M conv=noerror,sync 2>&1
    else
        dd if="$source_disk" of="$BACKUP_DEV" bs=4M conv=noerror,sync status=progress 2>&1
    fi
    local elapsed=$(( $(date +%s) - t0 ))
    log_ok "Backup done in ${elapsed}s."

    log_info "Verifying backup integrity (first 512MB)..."
    local sh dh
    sh=$(dd if="$source_disk" bs=1M count=512 2>/dev/null | md5sum | awk '{print $1}')
    dh=$(dd if="$BACKUP_DEV"  bs=1M count=512 2>/dev/null | md5sum | awk '{print $1}')
    if [[ "$sh" == "$dh" ]]; then
        log_ok "Backup verified (MD5: $sh)."
        state_set "PHASE_BACKUP" "complete"
        state_set "BACKUP_VERIFIED" "true"
    else
        die "BACKUP VERIFICATION FAILED. Source: $sh  Backup: $dh  DO NOT PROCEED."
    fi

    cat > "${LOG_DIR}/backup_metadata_${START_TIME}.txt" <<EOF
Backup Date : $(date)
Source      : $source_disk
Target      : $BACKUP_DEV
Duration    : ${elapsed}s
MD5 (512M)  : $sh
OS          : $(cat /etc/centos-release 2>/dev/null)
Kernel      : $(uname -r)
Restore cmd : dd if=$BACKUP_DEV of=$source_disk bs=4M conv=noerror,sync status=progress
              grub2-install $source_disk && grub2-mkconfig -o /boot/grub2/grub.cfg
EOF
    log_ok "Metadata: ${LOG_DIR}/backup_metadata_${START_TIME}.txt"
}

# ---------------------------------------------------------------------------
# Phase 3: Prepare system
# ---------------------------------------------------------------------------
phase_prepare() {
    log_section "Phase 3/6: Prepare System"

    if [[ "$(state_get PHASE_PREPARE)" == "complete" ]]; then
        log_ok "Prepare already completed — skipping."; return 0
    fi

    confirm "Begin system preparation? (yum update, cleanup, config backup)" || die "Aborted."

    # 1: yum update
    log_info "1/7: Updating all packages to latest CentOS 7 versions..."
    yum update -y 2>&1 | tail -20 || log_warn "yum update had non-zero exit — continuing."
    log_ok "System updated."

    # 2: clean cache
    log_info "2/7: Cleaning yum cache..."
    yum clean all 2>/dev/null || true
    rm -rf /var/cache/yum/* 2>/dev/null || true
    log_ok "Cache cleaned."

    # 3: conflicting packages
    log_info "3/7: Removing packages known to conflict with ELevate..."
    local conflict=(
        centos-release-scl centos-release-scl-rh
        python2-virtualenv python-virtualenv
        abrt abrt-addon-ccpp abrt-addon-kerneloops abrt-addon-pstoreoops
        abrt-addon-python abrt-addon-vmcore abrt-addon-xorg abrt-cli
        abrt-console-notification abrt-libs abrt-plugin-sosreport
    )
    for pkg in "${conflict[@]}"; do
        if rpm -q "$pkg" &>/dev/null 2>&1; then
            log_info "  Removing: $pkg"
            yum remove -y "$pkg" \
                --setopt=clean_requirements_on_remove=0 2>/dev/null || \
                log_warn "  Could not remove $pkg — continuing."
        fi
    done
    log_ok "Conflicting packages removed."

    # 4: old kernels
    log_info "4/7: Removing old kernels..."
    package-cleanup --oldkernels --count=1 -y 2>/dev/null || true
    log_ok "Old kernels removed."

    # 5: EPEL
    if ! rpm -q epel-release &>/dev/null 2>&1; then
        log_info "5/7: Installing EPEL..."
        yum install -y epel-release 2>/dev/null && log_ok "EPEL installed." || \
            log_warn "EPEL install failed — continuing."
    else
        log_ok "5/7: EPEL already present."
    fi

    # 6: disable third-party repos
    log_info "6/7: Temporarily disabling third-party repos..."
    find /etc/yum.repos.d/ -name "*.repo" \
        ! -name "CentOS-*.repo" ! -name "epel*.repo" \
        -exec bash -c 'sed -i "s/^enabled=1/enabled=0/" "$1"' _ {} \; 2>/dev/null || true
    log_ok "Third-party repos disabled (re-enable post-upgrade)."

    # 7: snapshot + config backup
    log_info "7/7: Saving package snapshot and config backups..."
    rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort \
        > "${LOG_DIR}/packages_before_${START_TIME}.txt"
    local cbd="${LOG_DIR}/config_backup_${START_TIME}"
    mkdir -p "$cbd"
    for d in /etc/httpd /etc/nginx /etc/mysql /etc/my.cnf.d /etc/php.ini \
              /etc/php.d /etc/postfix /etc/dovecot /etc/ssh /etc/cron.d \
              /etc/sysconfig/network-scripts /etc/NetworkManager; do
        [[ -e "$d" ]] && cp -a "$d" "$cbd/" 2>/dev/null && log_info "  Backed up: $d"
    done
    log_ok "Snapshots and configs saved: $cbd"

    state_set "PHASE_PREPARE" "complete"
    log_ok "System preparation complete."
}

# ---------------------------------------------------------------------------
# leapp binary resolver (6-stage, with install fallback)
# ---------------------------------------------------------------------------
resolve_leapp_bin() {
    # Stage 1: known paths
    for p in /usr/bin/leapp /bin/leapp /usr/local/bin/leapp; do
        [[ -x "$p" ]] && { LEAPP_BIN="$p"; log_ok "leapp: $LEAPP_BIN"; return 0; }
    done
    # Stage 2: PATH
    if command -v leapp &>/dev/null 2>&1; then
        LEAPP_BIN="$(command -v leapp)"; log_ok "leapp (PATH): $LEAPP_BIN"; return 0
    fi
    # Stage 3: filesystem search
    local f
    f=$(find / -name "leapp" -type f -executable 2>/dev/null | grep -v proc | grep -v sys | head -1 || true)
    [[ -n "$f" ]] && { LEAPP_BIN="$f"; log_ok "leapp (search): $LEAPP_BIN"; return 0; }
    # Stage 4: RPM file lists
    local rb
    for pkg in leapp python2-leapp leapp-upgrade-el7toel8; do
        rb=$(rpm -ql "$pkg" 2>/dev/null | grep -E "bin/leapp$" | head -1 || true)
        [[ -n "$rb" && -x "$rb" ]] && { LEAPP_BIN="$rb"; log_ok "leapp (RPM list): $LEAPP_BIN"; return 0; }
    done
    # Stage 5: install providers
    log_warn "leapp binary not found — attempting to install provider packages..."
    yum-config-manager --enable elevate &>/dev/null 2>&1 || true
    for pkg in leapp python2-leapp leapp-framework; do
        log_info "  Trying: yum install -y $pkg"
        yum install -y "$pkg" 2>&1 | tail -5 || true
        for p in /usr/bin/leapp /bin/leapp; do
            [[ -x "$p" ]] && { LEAPP_BIN="$p"; log_ok "leapp after install: $LEAPP_BIN"; return 0; }
        done
        command -v leapp &>/dev/null 2>&1 && { LEAPP_BIN="$(command -v leapp)"; return 0; }
    done
    # Stage 6: diagnostic and die
    log_error "══════════════════════════════════════════════════"
    log_error "FATAL: leapp binary not found. Diagnostic dump:"
    rpm -qa 2>/dev/null | grep -iE "leapp|elevate" | while read -r p; do log_error "  pkg: $p"; done
    yum repolist all 2>/dev/null | grep -i elevate | while read -r l; do log_error "  repo: $l"; done
    for pkg in leapp python2-leapp leapp-upgrade-el7toel8; do
        rpm -q "$pkg" &>/dev/null 2>&1 && \
            rpm -ql "$pkg" 2>/dev/null | while read -r fl; do log_error "  [$pkg] $fl"; done
    done
    log_error "Manual fix: yum-config-manager --enable elevate && yum install -y leapp"
    log_error "══════════════════════════════════════════════════"
    die "Cannot proceed without leapp binary."
}

# ---------------------------------------------------------------------------
# Phase 4: Install ELevate
# ---------------------------------------------------------------------------
phase_install_elevate() {
    log_section "Phase 4/6: Install ELevate"

    if [[ "$(state_get PHASE_ELEVATE)" == "complete" ]]; then
        log_ok "ELevate already installed — re-resolving binary..."
        resolve_leapp_bin; return 0
    fi

    local elevate_url="https://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm"

    # Install elevate-release
    if rpm -q elevate-release &>/dev/null 2>&1; then
        log_ok "elevate-release already installed."
    else
        log_info "Installing ELevate release package..."
        yum install -y "$elevate_url" 2>&1 | tail -10 || true
        rpm -q elevate-release &>/dev/null 2>&1 || die "elevate-release failed to install."
        log_ok "elevate-release installed."
    fi

    # Force-enable elevate repo (disabled by default after install)
    log_info "Enabling ELevate repo..."
    yum-config-manager --enable elevate &>/dev/null 2>&1 || \
        sed -i "s/enabled=0/enabled=1/" /etc/yum.repos.d/elevate.repo 2>/dev/null || true
    yum clean all &>/dev/null
    log_ok "ELevate repo enabled."

    # Install all leapp packages in one transaction
    log_info "Installing leapp packages (all in one transaction)..."
    case "$TARGET_DISTRO" in
        alma)
            yum install -y \
                leapp python2-leapp leapp-upgrade leapp-data-almalinux \
                2>&1 | tail -30 || true
            rpm -q leapp-data-almalinux &>/dev/null 2>&1 || die "leapp-data-almalinux failed to install."
            ;;
        rocky)
            yum install -y \
                leapp python2-leapp leapp-upgrade leapp-data-rocky \
                2>&1 | tail -30 || true
            rpm -q leapp-data-rocky &>/dev/null 2>&1 || die "leapp-data-rocky failed to install."
            ;;
    esac

    log_info "Installed leapp packages:"
    rpm -qa 2>/dev/null | grep -iE "leapp|elevate" | while read -r p; do log_info "  $p"; done

    resolve_leapp_bin
    state_set "PHASE_ELEVATE" "complete"
    log_ok "ELevate installed."
}

# ---------------------------------------------------------------------------
# Phase 4b: Fix leapp inhibitors (universal, idempotent)
# ---------------------------------------------------------------------------
_blacklist_driver() {
    local drv="$1"
    local bf="/etc/modprobe.d/${drv}.conf"
    [[ -f "$bf" ]] || { echo "blacklist ${drv}" > "$bf"; log_ok "  Blacklisted: $drv"; }
    lsmod 2>/dev/null | grep -q "^${drv} " && \
        rmmod "$drv" 2>/dev/null && log_ok "  Unloaded: $drv" || true
}

# ---------------------------------------------------------------------------
# Fix leapp nspawn container network — the container builds an EL8 userspace
# overlay and runs dnf inside systemd-nspawn. The overlay gets its own
# /etc/resolv.conf which is often empty/missing → all repo syncs fail even
# though host networking is fine.
# ---------------------------------------------------------------------------
fix_nspawn_network() {
    log_info "Checking leapp nspawn overlay network configuration..."

    # Locate the overlay directory leapp creates
    local overlay=""
    local search_paths=(
        "/var/lib/leapp/scratch/mounts/root_/system_overlay"
        "/var/lib/leapp/scratch/mounts/root_overlay"
    )
    # Also search dynamically in case path differs between leapp versions
    local found
    found=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    [[ -n "$found" ]] && search_paths+=("$found")

    for p in "${search_paths[@]}"; do
        if [[ -d "$p" ]]; then overlay="$p"; break; fi
    done

    if [[ -z "$overlay" ]]; then
        log_info "  nspawn overlay not yet created (normal before first preupgrade run)."
        return 0
    fi

    log_info "  Found overlay: $overlay"

    # Fix 1: /etc/resolv.conf — copy from host if missing or empty
    local overlay_resolv="${overlay}/etc/resolv.conf"
    mkdir -p "${overlay}/etc" 2>/dev/null || true
    if [[ ! -s "$overlay_resolv" ]]; then
        log_warn "  Overlay /etc/resolv.conf is missing or empty — copying from host..."
        cp -f /etc/resolv.conf "$overlay_resolv" 2>/dev/null || true
        log_ok "  Overlay resolv.conf fixed: $(cat "$overlay_resolv" | head -3 | tr '\n' ' ')"
    else
        log_ok "  Overlay resolv.conf present: $(head -1 "$overlay_resolv")"
    fi

    # Fix 2: /etc/hosts — copy from host if missing or empty
    local overlay_hosts="${overlay}/etc/hosts"
    if [[ ! -s "$overlay_hosts" ]]; then
        log_warn "  Overlay /etc/hosts is missing or empty — copying from host..."
        cp -f /etc/hosts "$overlay_hosts" 2>/dev/null || true
        log_ok "  Overlay /etc/hosts fixed."
    fi

    # Fix 3: verify DNS works inside the nspawn container
    # Use a lightweight test — just resolve one hostname
    log_info "  Testing DNS inside nspawn container..."
    local dns_ok=false
    if systemd-nspawn --register=no --quiet -D "$overlay" \
        bash -c "getent hosts repo.almalinux.org" &>/dev/null 2>&1; then
        dns_ok=true
        log_ok "  DNS inside nspawn: working."
    elif systemd-nspawn --register=no --quiet -D "$overlay" \
        bash -c "curl -4 --silent --max-time 5 --head https://repo.almalinux.org" &>/dev/null 2>&1; then
        dns_ok=true
        log_ok "  Network inside nspawn: working (curl test)."
    else
        log_warn "  DNS/network inside nspawn not verified — resolv.conf may still be wrong."
        log_info "  Host resolv.conf content:"
        cat /etc/resolv.conf | while read -r l; do log_info "    $l"; done
        log_info "  Overlay resolv.conf content:"
        cat "$overlay_resolv" 2>/dev/null | while read -r l; do log_info "    $l"; done || log_warn "  (empty)"
    fi

    # Fix 4: If NetworkManager is managing DNS, ensure it wrote resolv.conf
    if ! "$dns_ok" && command -v nmcli &>/dev/null 2>&1; then
        log_info "  Refreshing NetworkManager DNS..."
        nmcli networking off &>/dev/null 2>&1 || true
        sleep 1
        nmcli networking on &>/dev/null 2>&1 || true
        sleep 2
        # Re-copy after NM refresh
        cp -f /etc/resolv.conf "$overlay_resolv" 2>/dev/null || true
        log_ok "  resolv.conf re-synced after NM refresh."
    fi
}

phase_fix_inhibitors() {
    log_section "Phase 4b: Universal Inhibitor Remediation"

    # Step 1: leapp answerfile — pre-answer all known interactive prompts
    log_info "Step 1: Pre-answering all known leapp interactive prompts..."
    for ans in \
        "remove_pam_pkcs11_module_check.confirm=True" \
        "authselect_check.confirm=True" \
        "remove_ifcfg_files_check.confirm=True" \
        "grub_enableos_prober_check.confirm=True" \
        "verify_check_results.confirm=True"
    do
        "$LEAPP_BIN" answer --section "$ans" 2>/dev/null && log_ok "  Answered: $ans" || true
    done

    # Step 2: Generate leapp report if missing
    if [[ ! -f /var/log/leapp/leapp-report.txt ]]; then
        log_info "Step 2: Generating initial leapp report..."
        "$LEAPP_BIN" preupgrade 2>/dev/null || true
    else
        log_ok "Step 2: leapp report already exists."
    fi

    # Step 3: Dynamically blacklist drivers from report
    log_info "Step 3: Blacklisting removed drivers from leapp report..."
    if [[ -f /var/log/leapp/leapp-report.txt ]]; then
        local rdrvs=()
        while IFS= read -r line; do
            if echo "$line" | grep -qE "^\s+- [a-z0-9_]+$"; then
                local d; d=$(echo "$line" | tr -d ' -')
                [[ "$d" =~ ^[a-z0-9_]+$ ]] && [[ ${#d} -lt 40 ]] && rdrvs+=("$d")
            fi
        done < <(grep -A 20 "kernel drivers" /var/log/leapp/leapp-report.txt 2>/dev/null || true)
        for d in "${rdrvs[@]+"${rdrvs[@]}"}"; do _blacklist_driver "$d"; done
    fi

    # Step 4: Universally removed drivers (EL7→EL8 and EL8→EL9)
    log_info "Step 4: Blacklisting universally removed drivers..."
    local udrvs=(
        pata_acpi floppy isdn nozomi aoe
        snd_emu10k1_synth acerhdf asus_acpi bcm203x bpa10x
        lirc_serial mptbase mptctl mptfc mptlan mptsas mptscsih mptspi
        mtdblock n_hdlc pch_gbe snd_atiixp_modem snd_via82xx_modem
        ueagle_atm usbatm xusbatm
    )
    for d in "${udrvs[@]}"; do
        if lsmod 2>/dev/null | grep -q "^${d} " || \
           grep -q "$d" /var/log/leapp/leapp-report.txt 2>/dev/null; then
            _blacklist_driver "$d"
        fi
    done

    # Step 5: VDO
    if systemctl is-active --quiet vdo 2>/dev/null; then
        log_warn "VDO detected — stopping before upgrade..."
        systemctl stop vdo 2>/dev/null || true
        systemctl disable vdo 2>/dev/null || true
        log_ok "VDO stopped."
    fi

    # Step 6: Legacy eth0 naming
    if ip link show 2>/dev/null | grep -q "^[0-9]*: eth[0-9]"; then
        log_warn "Legacy eth0 name — adding net.ifnames=0 biosdevname=0 kernel args..."
        grubby --update-kernel=ALL --args="net.ifnames=0 biosdevname=0" 2>/dev/null || true
    fi

    # Step 7: Postfix compatibility
    command -v postconf &>/dev/null 2>&1 && \
        postconf -e compatibility_level=2 2>/dev/null && log_ok "Postfix compatibility_level=2." || true

    # Step 8: ABRT — safe removal, no cascade
    local abrt; abrt=$(rpm -qa 2>/dev/null | grep "^abrt" || true)
    if [[ -n "$abrt" ]]; then
        log_info "Removing ABRT packages (safe, no autoremove)..."
        echo "$abrt" | xargs yum remove -y \
            --setopt=clean_requirements_on_remove=0 2>/dev/null || true
        log_ok "ABRT removed."
    fi

    # Safety: reinstall leapp if ABRT removal cascade-removed it
    if ! rpm -q leapp-upgrade &>/dev/null 2>&1 && \
       ! rpm -q leapp-upgrade-el7toel8 &>/dev/null 2>&1; then
        log_warn "leapp-upgrade missing (cascade-removed) — reinstalling..."
        yum-config-manager --enable elevate &>/dev/null 2>&1 || true
        case "$TARGET_DISTRO" in
            alma) yum install -y leapp leapp-upgrade leapp-data-almalinux 2>&1 | tail -10 || true ;;
            rocky) yum install -y leapp leapp-upgrade leapp-data-rocky 2>&1 | tail -10 || true ;;
        esac
        resolve_leapp_bin
        log_ok "leapp restored."
    fi

    # Step 9: /etc/redhat-release symlink
    [[ ! -f /etc/redhat-release ]] && [[ -f /etc/centos-release ]] && \
        ln -sf /etc/centos-release /etc/redhat-release 2>/dev/null && log_ok "redhat-release symlink fixed." || true

    # Step 10: leapp directories
    mkdir -p /var/log/leapp /etc/leapp/files 2>/dev/null || true

    # Step 11: IPv6 — disable if broken (leapp nspawn inherits host network)
    local ipv6off; ipv6off=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo "1")
    if [[ "$ipv6off" == "0" ]] && ! ping6 -c 1 -W 3 2620:fe::fe &>/dev/null 2>&1; then
        log_warn "Broken IPv6 detected — disabling to prevent leapp nspawn repo failures..."
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null || true
        grep -q "disable_ipv6" /etc/sysctl.conf 2>/dev/null || \
            printf '\n# el8-migration\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' >> /etc/sysctl.conf
        log_ok "IPv6 disabled."
    fi

    # Step 12: Fix nspawn overlay network (resolv.conf missing/empty in container)
    # This is the most common cause of "Failed to synchronize cache for repo"
    # even when host network is working perfectly.
    log_info "Step 12: Fixing nspawn overlay network configuration..."
    fix_nspawn_network

    state_set "PHASE_INHIBITORS" "complete"
    log_ok "Inhibitor remediation complete."
}

# ---------------------------------------------------------------------------
# Phase 5: leapp preupgrade (with auto-retry)
# ---------------------------------------------------------------------------
phase_preupgrade() {
    log_section "Phase 5/6: leapp preupgrade (DRY RUN)"

    if [[ "$(state_get PHASE_PREUPGRADE)" == "complete" ]]; then
        log_ok "preupgrade already passed — skipping."; return 0
    fi

    log_info "This is a DRY RUN — no changes are made to the system."

    local max_attempts=3
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true
        log_info "leapp preupgrade — attempt $attempt/$max_attempts..."

        local plog="${LOG_DIR}/leapp_preupgrade_${START_TIME}_attempt${attempt}.log"
        "$LEAPP_BIN" preupgrade 2>&1 | tee "$plog" || true

        # Fix nspawn overlay network immediately after leapp creates it.
        # The overlay is built during preupgrade — resolv.conf is often empty.
        # This must run AFTER preupgrade (overlay exists) and BEFORE the next attempt.
        fix_nspawn_network

        if [[ ! -f /var/log/leapp/leapp-report.txt ]]; then
            log_error "leapp report not generated. See: $plog"
            die "leapp preupgrade failed to produce a report."
        fi

        cp /var/log/leapp/leapp-report.txt "${LOG_DIR}/leapp_report_${START_TIME}_attempt${attempt}.txt"

        # Count hard blockers
        local inhibitor_count error_count
        inhibitor_count=$(grep -c "^Risk Factor: high (error)" /var/log/leapp/leapp-report.txt 2>/dev/null || echo "0")
        error_count=$(grep -c "Following errors occurred" /var/log/leapp/leapp-report.txt 2>/dev/null || echo "0")

        if [[ "$inhibitor_count" -eq 0 ]] && [[ "$error_count" -eq 0 ]]; then
            log_ok "leapp preupgrade: CLEAR — 0 inhibitors, 0 errors."
            state_set "PHASE_PREUPGRADE" "complete"
            return 0
        fi

        # Show report
        echo
        log_warn "Inhibitors/errors found (inhibitors: $inhibitor_count, errors: $error_count)"
        echo -e "\n${YELLOW}══════════ leapp report ══════════${RESET}"
        cat /var/log/leapp/leapp-report.txt
        echo -e "${YELLOW}══════════════════════════════════${RESET}\n"

        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Running auto-remediation (attempt $attempt)..."
            state_set "PHASE_INHIBITORS" ""   # reset so fix runs again
            phase_fix_inhibitors
        else
            echo
            log_error "═══════════════════════════════════════════════════════════"
            log_error "MANUAL ACTION REQUIRED:"
            log_error "Inhibitors remain after $max_attempts auto-remediation attempts."
            log_error ""
            log_error "1. Review report: cat /var/log/leapp/leapp-report.txt"
            log_error "2. Fix each INHIBITOR listed above manually"
            log_error "3. Re-run: sudo $SCRIPT_NAME --migrate"
            log_error "   (Migration will resume from this phase)"
            log_error "═══════════════════════════════════════════════════════════"
            die "leapp preupgrade blocked. See report above."
        fi
    done
}

# ---------------------------------------------------------------------------
# Phase 6: leapp upgrade — POINT OF NO RETURN
# ---------------------------------------------------------------------------
phase_upgrade() {
    log_section "Phase 6/6: leapp upgrade — POINT OF NO RETURN"

    echo
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${RED}${BOLD}║  ⚠  FINAL WARNING — THIS CANNOT BE UNDONE               ║${RESET}"
    echo -e "${RED}${BOLD}║                                                          ║${RESET}"
    printf  "${RED}${BOLD}║  Target  : %-47s║${RESET}\n" "${TARGET_DISTRO^^} Linux 8"
    echo -e "${RED}${BOLD}║  Action  : In-place OS upgrade + automatic reboot        ║${RESET}"
    echo -e "${RED}${BOLD}║  Recovery: Only via backup restore if something fails    ║${RESET}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo

    confirm "FINAL CONFIRMATION: Upgrade to ${TARGET_DISTRO^^} Linux 8 and reboot?" || \
        die "Upgrade cancelled at final confirmation."

    # Final answers
    "$LEAPP_BIN" answer --section remove_pam_pkcs11_module_check.confirm=True 2>/dev/null || true
    "$LEAPP_BIN" answer --section authselect_check.confirm=True 2>/dev/null || true

    state_set "PHASE_UPGRADE" "started"
    log_info "Running leapp upgrade — system will reboot automatically..."
    echo

    "$LEAPP_BIN" upgrade 2>&1 | tee "${LOG_DIR}/leapp_upgrade_${START_TIME}.log" || true

    # Should not reach here normally
    log_info "leapp upgrade exited. Waiting for reboot..."
    log_info "If no reboot in 2 minutes, run: reboot"
    log_info "After reboot: sudo $SCRIPT_NAME --post-upgrade"
}

# ===========================================================================
#  SECTION 4 — POST-UPGRADE VALIDATION
# ===========================================================================

run_post_upgrade() {
    log_section "POST-UPGRADE VALIDATION"

    echo "--- OS Release ---"
    cat /etc/os-release 2>/dev/null || echo "(not found)"
    echo

    echo "--- Kernel ---"
    uname -a; echo

    # Confirm target distro
    if [[ -f /etc/almalinux-release ]]; then
        log_ok "AlmaLinux confirmed: $(cat /etc/almalinux-release)"
    elif [[ -f /etc/rocky-release ]]; then
        log_ok "Rocky Linux confirmed: $(cat /etc/rocky-release)"
    elif grep -q " 8" /etc/redhat-release 2>/dev/null; then
        log_ok "EL8 confirmed: $(cat /etc/redhat-release)"
    else
        log_error "Cannot confirm EL8. Check /etc/os-release manually."
    fi

    # Package manager
    echo "--- dnf version ---"
    dnf --version 2>/dev/null || log_error "dnf not available!"
    echo

    # Services
    log_section "Service Health"
    for s in sshd NetworkManager rsyslog crond; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            log_ok "$s: running"
        else
            log_warn "$s: NOT running — check: systemctl status $s"
        fi
    done
    echo
    echo "--- Failed systemd units ---"
    systemctl --failed 2>/dev/null || true
    echo

    # Network
    log_section "Network"
    ping -c2 -W3 8.8.8.8 &>/dev/null && log_ok "IPv4 connectivity OK." || log_warn "No IPv4 to 8.8.8.8."
    ping -c2 -W3 google.com &>/dev/null && log_ok "DNS OK." || log_warn "DNS may be broken."

    # EPEL
    if ! rpm -q epel-release &>/dev/null 2>&1; then
        log_info "Installing EPEL for EL8..."
        if [[ -f /etc/rocky-release ]]; then
            dnf config-manager --enable crb 2>/dev/null || \
            dnf config-manager --set-enabled powertools 2>/dev/null || true
        fi
        dnf install -y epel-release 2>/dev/null && log_ok "EPEL installed." || log_warn "EPEL install failed."
    else
        log_ok "EPEL present."
    fi

    # Config conflicts
    log_section "Configuration Conflicts"
    echo "--- .rpmsave (old config backed up by RPM) ---"
    find /etc -name "*.rpmsave" 2>/dev/null | head -20
    echo
    echo "--- .rpmnew (new default config from RPM) ---"
    find /etc -name "*.rpmnew" 2>/dev/null | head -20
    echo
    log_warn "Review and merge .rpmsave / .rpmnew files — these indicate config changes from upgraded packages."

    # Package delta
    log_section "Package Delta"
    rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort \
        > "${LOG_DIR}/packages_after_${START_TIME}.txt"
    local bf; bf=$(ls -t "${LOG_DIR}"/packages_before_*.txt 2>/dev/null | head -1 || echo "")
    if [[ -n "$bf" ]]; then
        echo "Packages removed during upgrade:"
        diff "$bf" "${LOG_DIR}/packages_after_${START_TIME}.txt" 2>/dev/null | grep "^<" | head -20
        echo
        echo "Packages added during upgrade:"
        diff "$bf" "${LOG_DIR}/packages_after_${START_TIME}.txt" 2>/dev/null | grep "^>" | head -20
    fi

    # Checklist
    log_section "Post-Upgrade Action Checklist"
    echo
    echo -e "  ${CYAN}1.${RESET} Set Python 3 as default:"
    echo -e "       alternatives --set python /usr/bin/python3"
    echo
    echo -e "  ${CYAN}2.${RESET} Re-enable SELinux enforcing:"
    echo -e "       sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config"
    echo -e "       touch /.autorelabel && reboot"
    echo
    echo -e "  ${CYAN}3.${RESET} Apply security patches:"
    echo -e "       dnf update --security -y"
    echo
    echo -e "  ${CYAN}4.${RESET} Review crypto policies:"
    echo -e "       update-crypto-policies --show"
    echo
    echo -e "  ${CYAN}5.${RESET} Diff SSH config changes:"
    echo -e "       diff /etc/ssh/sshd_config /etc/ssh/sshd_config.rpmsave 2>/dev/null"
    echo
    if [[ -f /etc/rocky-release ]]; then
        echo -e "  ${CYAN}6.${RESET} Rocky: Enable CRB repo:"
        echo -e "       dnf config-manager --enable crb"
        echo
    fi
    echo -e "  ${CYAN}7.${RESET} Re-enable third-party repos with EL8-compatible versions:"
    echo -e "       Review each file in /etc/yum.repos.d/ and update URLs"
    echo
    echo -e "  ${CYAN}8.${RESET} Future EL8 → EL9 upgrade when ready:"
    echo -e "       dnf update -y"
    echo -e "       dnf install -y https://repo.almalinux.org/elevate/elevate-release-latest-el8.noarch.rpm"
    echo -e "       dnf install -y leapp-upgrade leapp-data-almalinux  # or leapp-data-rocky"
    echo -e "       leapp preupgrade && leapp upgrade"
    echo

    log_ok "Post-upgrade validation complete."
}

# ===========================================================================
#  SECTION 5 — MIGRATION WIZARD
# ===========================================================================

do_migrate() {
    log_section "MIGRATION WIZARD"

    # Run preflight first — always
    log_info "Running preflight assessment..."
    run_preflight
    print_preflight_report

    # Hard stop on blockers
    if [[ ${#PREFLIGHT_BLOCKS[@]} -gt 0 ]]; then
        echo
        log_error "══════════════════════════════════════════════════"
        log_error "MIGRATION BLOCKED — ${#PREFLIGHT_BLOCKS[@]} blocker(s) must be resolved:"
        for b in "${PREFLIGHT_BLOCKS[@]+"${PREFLIGHT_BLOCKS[@]}"}"; do log_error "  ✖ $b"; done
        log_error "══════════════════════════════════════════════════"
        die "Resolve the blockers above and re-run."
    fi

    # Warn on warnings
    if [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]]; then
        echo
        log_warn "${#PREFLIGHT_WARNS[@]} warning(s) detected — review above."
        confirm "Warnings present. Proceed anyway?" || die "Aborted by user."
    fi

    # Apply auto-fixes before proceeding
    if [[ ${#PREFLIGHT_AUTOS[@]} -gt 0 ]]; then
        log_info "Applying ${#PREFLIGHT_AUTOS[@]} auto-fix(es)..."
        run_autofix
    fi

    state_set "PHASE_ASSESS" "complete"

    # Run all phases
    phase_select_target
    phase_backup
    phase_prepare
    phase_install_elevate
    phase_fix_inhibitors
    phase_preupgrade
    phase_upgrade
}

# ===========================================================================
#  SECTION 6 — INTERACTIVE MAIN MENU
# ===========================================================================

show_migration_status() {
    local sf="${LOG_DIR}/.migration_state"
    [[ -f "$sf" ]] || return
    echo -e "  ${BOLD}Current migration progress:${RESET}"
    local fields=(TARGET_DISTRO PHASE_ASSESS PHASE_BACKUP PHASE_PREPARE PHASE_ELEVATE PHASE_PREUPGRADE PHASE_UPGRADE)
    for f in "${fields[@]}"; do
        local v; v=$(grep "^${f}=" "$sf" 2>/dev/null | cut -d= -f2- || echo "—")
        printf "    %-20s %s\n" "$f:" "${v:-—}"
    done
    echo
}

main_menu() {
    while true; do
        banner
        show_migration_status

        echo -e "  ${BOLD}${WHITE}Main Menu${RESET}"
        echo
        echo -e "  ${CYAN}1)${RESET} Assess       — Preflight check (read-only, no changes)"
        echo -e "  ${CYAN}2)${RESET} Fix          — Auto-fix safe issues found by assessment"
        echo -e "  ${CYAN}3)${RESET} Migrate      — Full migration wizard (phase by phase)"
        echo -e "  ${CYAN}4)${RESET} Post-upgrade — Validate after upgrade completes"
        echo -e "  ${CYAN}5)${RESET} View report  — Open last preflight report"
        echo -e "  ${CYAN}6)${RESET} Reset state  — Clear saved progress (start fresh)"
        echo -e "  ${CYAN}0)${RESET} Exit"
        echo
        echo -en "  ${YELLOW}Choice: ${RESET}"
        local ch; read -r ch

        case "$ch" in
            1)
                init_logging
                run_preflight
                print_preflight_report
                state_set "PHASE_ASSESS" "complete"
                echo; echo -en "${YELLOW}  Press Enter to return to menu...${RESET}"; read -r
                ;;
            2)
                init_logging
                if [[ "$(state_get PHASE_ASSESS)" != "complete" ]]; then
                    log_warn "No assessment found. Running assessment first..."
                    run_preflight; print_preflight_report; state_set "PHASE_ASSESS" "complete"
                fi
                run_autofix
                echo; echo -en "${YELLOW}  Press Enter...${RESET}"; read -r
                ;;
            3)
                init_logging
                do_migrate
                echo; echo -en "${YELLOW}  Press Enter...${RESET}"; read -r 2>/dev/null || true
                ;;
            4)
                init_logging
                run_post_upgrade
                echo; echo -en "${YELLOW}  Press Enter...${RESET}"; read -r
                ;;
            5)
                local rpt; rpt=$(ls -t "${LOG_DIR}"/preflight_report_*.txt 2>/dev/null | head -1 || echo "")
                if [[ -n "$rpt" ]]; then less "$rpt"
                else echo "  No report found. Run assessment first."; sleep 2; fi
                ;;
            6)
                confirm "Reset all state? (Does NOT undo system changes)" && \
                    rm -f "${LOG_DIR}/.migration_state" && preflight_reset && log_ok "State reset."
                sleep 1
                ;;
            0) echo; log_info "Exiting."; exit 0 ;;
            *) echo "  Invalid choice."; sleep 1 ;;
        esac
    done
}

# ===========================================================================
#  ENTRY POINT
# ===========================================================================

parse_args "$@"
state_init

case "$MODE" in
    "assess")
        init_logging; banner
        [[ $EUID -ne 0 ]] && die "Must run as root."
        run_preflight; print_preflight_report
        [[ ${#PREFLIGHT_BLOCKS[@]} -gt 0 ]] && exit 2
        [[ ${#PREFLIGHT_WARNS[@]} -gt 0 ]] && exit 1
        exit 0
        ;;
    "fix")
        init_logging; banner
        [[ $EUID -ne 0 ]] && die "Must run as root."
        run_autofix
        ;;
    "migrate")
        init_logging; banner
        [[ $EUID -ne 0 ]] && die "Must run as root."
        do_migrate
        ;;
    "post-upgrade")
        init_logging; banner
        [[ $EUID -ne 0 ]] && die "Must run as root."
        run_post_upgrade
        ;;
    ""|"menu")
        [[ $EUID -ne 0 ]] && die "Must run as root."
        init_logging
        main_menu
        ;;
    *)
        echo "Unknown mode: $MODE"; usage; exit 1 ;;
esac
