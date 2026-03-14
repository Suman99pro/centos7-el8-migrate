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
readonly SCRIPT_VERSION="3.10.0"
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

    # Check if a leapp nspawn overlay exists and has broken network config
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    if [[ -n "$overlay" ]]; then
        local issues=()
        [[ ! -s "${overlay}/etc/resolv.conf" ]] && issues+=("resolv.conf missing/empty")
        [[ ! -s "${overlay}/etc/pki/tls/certs/ca-bundle.crt" ]] && issues+=("CA bundle missing/empty")
        if [[ ${#issues[@]} -gt 0 ]]; then
            pf_auto "leapp nspawn overlay has network issues: ${issues[*]}. Will be fixed — causes all repo syncs to fail inside the upgrade container."
        else
            pf_pass "leapp nspawn overlay network config OK."
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

    # nspawn bypass — if overlay exists from a previous run, pre-fix it
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    if [[ -n "$overlay" ]]; then
        log_info "leapp overlay found — applying nspawn network bypass fixes..."
        fix_nspawn_network
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

    # Patch the leapp actor immediately after install.
    # This is the primary fix for enp0s3 going down during preupgrade.
    # Must happen here — before ANY leapp command runs — so the actor
    # never executes without --network-none.
    log_info "Patching leapp actor (prevent NIC capture by nspawn)..."
    _install_nspawn_wrapper
    _patch_leapp_actor
    _prevent_nspawn_network_namespace

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
# _find_overlay — print overlay path or empty string
# ---------------------------------------------------------------------------
_find_overlay() {
    local p
    for p in \
        "/var/lib/leapp/scratch/mounts/root_/system_overlay" \
        "/var/lib/leapp/scratch/mounts/root_overlay"
    do
        [[ -d "$p" ]] && { echo "$p"; return; }
    done
    find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" \
        -type d 2>/dev/null | head -1 || true
}

# ---------------------------------------------------------------------------
# _leapp_repo_file — print path to leapp EL8 .repo file or empty string
# ---------------------------------------------------------------------------
_leapp_repo_file() {
    find /etc/leapp/files/ -name "*.repo" 2>/dev/null | head -1 || true
}

# ---------------------------------------------------------------------------
# _patch_leapp_repos — set sslverify=0 gpgcheck=0 in all leapp EL8 repo files
# Safe: only touches the bootstrap repo leapp uses for the nspawn install.
# The installed EL8 system gets its own clean repo files post-upgrade.
# ---------------------------------------------------------------------------
_patch_leapp_repos() {
    local repo_file; repo_file=$(_leapp_repo_file)
    [[ -z "$repo_file" ]] && return 0

    log_info "  Patching leapp repo file: $repo_file"

    # Use python2 (available on CentOS 7) for reliable INI manipulation
    python2 - "$repo_file" << 'PYEOF' 2>/dev/null && { log_ok "  Repo file patched."; return 0; }
import sys, re
path = sys.argv[1]
with open(path) as f:
    c = f.read()
# Force sslverify=0 and gpgcheck=0 in every section
for key in ('sslverify', 'gpgcheck'):
    # Replace existing values
    c = re.sub(r'^' + key + r'\s*=.*$', key + '=0', c, flags=re.M)
    # Add after section header if missing
    def add_if_missing(m):
        header = m.group(0)
        rest   = c[m.end():]
        next_section = re.search(r'^\[', rest, re.M)
        block = rest[:next_section.start()] if next_section else rest
        if key not in block:
            return header + '\n' + key + '=0'
        return header
    c = re.sub(r'^\[.+\]$', add_if_missing, c, flags=re.M)
with open(path, 'w') as f:
    f.write(c)
sys.exit(0)
PYEOF

    # Fallback: sed
    sed -i \
        -e 's/^sslverify\s*=.*/sslverify=0/' \
        -e 's/^gpgcheck\s*=.*/gpgcheck=0/' \
        "$repo_file" 2>/dev/null || true
    grep -q "^sslverify" "$repo_file" || \
        sed -i '/^\[/a sslverify=0\ngpgcheck=0' "$repo_file" 2>/dev/null || true
    log_ok "  Repo file patched (sed fallback)."
}

# ---------------------------------------------------------------------------
# _host_dnf_bootstrap
#
# THE CORE FIX for "Unable to install RHEL 8 userspace packages"
#
# Root cause (confirmed through repeated testing):
#   systemd-nspawn on CentOS 7 (systemd v219) running an overlay rootfs on
#   a KVM guest has no working network inside the container. This is a hard
#   limitation of nspawn v219 + overlay mounts — NOT fixable by copying
#   resolv.conf, CA certs, or any config files into the overlay.
#
# Solution: Run the exact dnf install command leapp's nspawn actor would run,
#   but from the HOST which has full network. The EL8 installroot gets
#   pre-populated. When leapp's nspawn runs next, packages are already
#   installed and no network access is needed inside the container.
#
# This function is safe to call multiple times (idempotent).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _find_primary_nic — find the real physical/virtual-machine NIC
# Returns the interface name that should carry the default route.
# Explicitly skips: lo, virbr*, veth*, docker*, br-*, bond (unless it has IP)
# ---------------------------------------------------------------------------
_find_primary_nic() {
    # First: NIC that currently has the default route
    local nic
    nic=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    [[ -n "$nic" ]] && { echo "$nic"; return; }

    # Second: use the NIC saved at script start (most reliable)
    [[ -n "${PRIMARY_NIC:-}" ]] && { echo "$PRIMARY_NIC"; return; }

    # Third: find non-virtual NICs with a link (exclude virbr/veth/docker/br-)
    while IFS= read -r iface; do
        [[ "$iface" =~ ^(lo|virbr|veth|docker|br-|vnet|tun|tap) ]] && continue
        ip link show "$iface" 2>/dev/null | grep -q "state UP\|state UNKNOWN" || continue
        echo "$iface"; return
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

    # Fourth: any non-virtual NIC even if DOWN
    while IFS= read -r iface; do
        [[ "$iface" =~ ^(lo|virbr|veth|docker|br-|vnet|tun|tap) ]] && continue
        echo "$iface"; return
    done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')
}

# ---------------------------------------------------------------------------
# _restore_network — bring the primary NIC back up if nspawn took it down
# Only touches the real NIC — never touches virbr0, veth, docker bridges
# ---------------------------------------------------------------------------
_restore_network() {
    # If default route exists, network is fine
    if ip route 2>/dev/null | grep -q "^default"; then
        local nic gw
        nic=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
        gw=$(ip route  2>/dev/null | awk '/^default/{print $3; exit}')
        log_ok "  Network OK: $nic via $gw"
        return 0
    fi

    log_warn "  No default route — network is down. Attempting recovery..."

    local nic; nic=$(_find_primary_nic)
    if [[ -z "$nic" ]]; then
        log_warn "  Cannot identify primary NIC — skipping recovery."
        return 0
    fi

    log_info "  Primary NIC: $nic — bringing up..."

    # Bring link up
    ip link set "$nic" up 2>/dev/null || true
    sleep 2

    # Try NetworkManager first (cleanest on CentOS 7)
    if command -v nmcli &>/dev/null 2>&1; then
        log_info "  Reconnecting via NetworkManager..."
        nmcli device connect "$nic" 2>/dev/null || true
        sleep 4
        if ip route 2>/dev/null | grep -q "^default"; then
            log_ok "  Network restored via NetworkManager ($nic)."
            return 0
        fi
    fi

    # Fallback: dhclient — kill any competing instance first
    if command -v dhclient &>/dev/null 2>&1; then
        log_info "  Trying dhclient on $nic..."
        # Kill any existing dhclient for this NIC to avoid conflicts
        pkill -f "dhclient.*$nic" 2>/dev/null || true
        sleep 1
        dhclient "$nic" 2>/dev/null
        sleep 4
        if ip route 2>/dev/null | grep -q "^default"; then
            log_ok "  Network restored via dhclient ($nic)."
            return 0
        fi
    fi

    # Last resort: restart NetworkManager entirely
    log_warn "  Restarting NetworkManager..."
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 6
    if ip route 2>/dev/null | grep -q "^default"; then
        log_ok "  Network restored via NetworkManager restart."
    else
        log_warn "  Network could not be restored. Migration continues — check connectivity."
    fi
}

# ---------------------------------------------------------------------------
# _install_nspawn_wrapper — THE definitive fix for enp0s3 disappearing
#
# Every previous approach (regex patching Python files) failed because the
# nspawn command is assembled dynamically across multiple files. The wrapper
# approach is bulletproof: replace the nspawn binary itself with a shell
# script that injects --network-none into every single call, no matter which
# leapp actor triggers it or how arguments are built.
# ---------------------------------------------------------------------------
_install_nspawn_wrapper() {
    log_info "  [A] Installing systemd-nspawn --network-none wrapper..."

    local real_bin="/usr/bin/systemd-nspawn"
    local real_backup="/usr/bin/systemd-nspawn.el8migrate.real"
    local marker="EL8MIGRATE_WRAPPER"

    if grep -q "$marker" "$real_bin" 2>/dev/null; then
        log_ok "  nspawn wrapper already in place."
        return 0
    fi

    if [[ ! -f "$real_bin" ]]; then
        log_warn "  $real_bin not found — skipping wrapper."
        return 0
    fi

    [[ -f "$real_backup" ]] || cp -f "$real_bin" "$real_backup" 2>/dev/null || {
        log_warn "  Cannot back up $real_bin — skipping wrapper."
        return 0
    }

    cat > "$real_bin" << 'WRAPPER'
#!/usr/bin/env bash
# EL8MIGRATE_WRAPPER — injects --network-none into every nspawn call.
# Prevents systemd-nspawn v219 from moving enp0s3 into container namespace.
REAL="/usr/bin/systemd-nspawn.el8migrate.real"
ARGS=("$@")
has_network_none=false; is_boot=false
for a in "${ARGS[@]}"; do
    [[ "$a" == "--network-none" ]] && has_network_none=true
    [[ "$a" == "--boot" || "$a" == "-b" ]] && is_boot=true
done
if [[ "$has_network_none" == false && "$is_boot" == false ]]; then
    exec "$REAL" --network-none --setenv=LEAPP_NO_RHSM=1 "${ARGS[@]}"
else
    exec "$REAL" "${ARGS[@]}"
fi
WRAPPER

    chmod +x "$real_bin" 2>/dev/null || true

    if grep -q "$marker" "$real_bin" 2>/dev/null; then
        log_ok "  nspawn wrapper installed — NIC capture prevented for all leapp actors."
    else
        cp -f "$real_backup" "$real_bin" 2>/dev/null || true
        log_warn "  Wrapper write failed — restored original."
    fi
}

_remove_nspawn_wrapper() {
    local real_bin="/usr/bin/systemd-nspawn"
    local real_backup="/usr/bin/systemd-nspawn.el8migrate.real"
    if [[ -f "$real_backup" ]]; then
        cp -f "$real_backup" "$real_bin" 2>/dev/null && \
            rm -f "$real_backup" && \
            log_ok "systemd-nspawn restored to original."
    fi
}

# Keep Python actor patching as belt-and-suspenders
_patch_leapp_actor() {
    log_info "  [A2] Patching leapp Python actors (belt-and-suspenders)..."
    local found=false
    for d in /usr/share/leapp-repository /etc/leapp/repos.d /usr/lib/leapp; do
        [[ -d "$d" ]] || continue
        while IFS= read -r f; do
            grep -q "systemd-nspawn" "$f" 2>/dev/null || continue
            grep -q "PATCHED_EL8_MIGRATE" "$f" 2>/dev/null && { found=true; continue; }
            [[ -f "${f}.el8migrate.orig" ]] || cp -f "$f" "${f}.el8migrate.orig" 2>/dev/null || true
            python2 - "$f" << 'PYEOF' 2>/dev/null && { log_ok "  Patched: $(basename "$f")"; found=true; } || true
import sys, re
p = sys.argv[1]
with open(p) as fh: c = fh.read()
orig = c
c = re.sub(r"'--register=no'(\s*,)", r"'--register=no', '--network-none'\1", c)
c = re.sub(r'"--register=no"(\s*,)', r'"--register=no", "--network-none"\1', c)
c = re.sub(r'(systemd-nspawn\s+--register=no(?!\s+--network-none))', r'\1 --network-none', c)
if c != orig:
    c += '\n# PATCHED_EL8_MIGRATE\n'
    with open(p, 'w') as fh: fh.write(c)
    sys.exit(0)
sys.exit(1)
PYEOF
        done < <(find "$d" -name "*.py" 2>/dev/null)
    done
    [[ "$found" == true ]] || log_info "  No actor files found yet."
}

# ---------------------------------------------------------------------------
# _prevent_nspawn_network_namespace
# Belt-and-suspenders: systemd-level config to stop nspawn taking the NIC
# ---------------------------------------------------------------------------
_prevent_nspawn_network_namespace() {
    log_info "  [B] Configuring systemd to prevent nspawn NIC capture..."

    # Drop-in for systemd-nspawn@.service — disable private networking
    local dropin_dir="/etc/systemd/system/systemd-nspawn@.service.d"
    mkdir -p "$dropin_dir" 2>/dev/null || true
    cat > "${dropin_dir}/no-private-network.conf" << 'EOF'
[Service]
PrivateNetwork=no
EOF

    # /etc/systemd/nspawn/ config files — cover all possible container names
    # leapp uses the directory name of the overlay as the container name
    local nspawn_conf_dir="/etc/systemd/nspawn"
    mkdir -p "$nspawn_conf_dir" 2>/dev/null || true
    for name in leapp root_ system_overlay mounts; do
        cat > "${nspawn_conf_dir}/${name}.nspawn" << 'EOF'
[Network]
Private=no
VirtualEthernet=no
EOF
    done

    # Stop systemd-networkd if running — it's the service that manages
    # the nspawn veth interfaces and can interfere with the host NIC
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        log_warn "  systemd-networkd is running — stopping it (leapp doesn't need it)..."
        systemctl stop systemd-networkd 2>/dev/null || true
        systemctl disable systemd-networkd 2>/dev/null || true
        log_ok "  systemd-networkd stopped."
    fi

    systemctl daemon-reload 2>/dev/null || true
    log_ok "  nspawn network namespace prevention configured."
}

_host_dnf_bootstrap() {
    local overlay="$1"
    local leapp_repo; leapp_repo=$(_leapp_repo_file)

    if [[ -z "$leapp_repo" ]]; then
        log_warn "  _host_dnf_bootstrap: no leapp repo file found yet — skipping."
        return 0
    fi

    # Target: the installroot leapp's actor populates inside the overlay
    local installroot="${overlay}/el8target"
    mkdir -p "$installroot" 2>/dev/null || true

    # Already done?
    if [[ -f "${installroot}/usr/bin/dnf" ]] || [[ -f "${installroot}/bin/dnf" ]]; then
        log_ok "  EL8 installroot already has dnf — bootstrap already complete."
        return 0
    fi

    log_info "  Pre-populating EL8 installroot from host (bypassing nspawn network)..."
    log_info "  Installroot: $installroot"

    # Ensure dnf on host
    if ! command -v dnf &>/dev/null 2>&1; then
        log_info "  Installing dnf on host..."
        yum install -y dnf 2>/dev/null | tail -5 || true
    fi
    if ! command -v dnf &>/dev/null 2>&1; then
        log_warn "  dnf unavailable on host — cannot bootstrap installroot."
        return 0
    fi

    # Work dir for host-side dnf config
    local work_dir="/var/lib/leapp/scratch/host_dnf_work"
    mkdir -p "${work_dir}/repos.d" 2>/dev/null || true

    # Patch repo file: sslverify=0, gpgcheck=0 (bootstrap only, not installed system)
    python2 - "$leapp_repo" "${work_dir}/repos.d/el8.repo" << 'PYEOF' 2>/dev/null || \
        cp -f "$leapp_repo" "${work_dir}/repos.d/el8.repo"
import sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    c = f.read()
for key in ('sslverify', 'gpgcheck'):
    c = re.sub(r'^' + key + r'\s*=.*$', key + '=0', c, flags=re.M)
    if key not in c:
        c = re.sub(r'(\[[^\]]+\])', r'\1\n' + key + '=0', c)
with open(dst, 'w') as f:
    f.write(c)
PYEOF

    # Host dnf.conf — isolated from system repos
    cat > "${work_dir}/dnf.conf" << CONF
[main]
gpgcheck=0
sslverify=0
installonly_limit=3
clean_requirements_on_remove=True
reposdir=${work_dir}/repos.d
CONF

    # Enable all repos leapp defined
    local enable_repos=()
    while IFS= read -r line; do
        [[ "$line" =~ ^\[([^\]]+)\]$ ]] && enable_repos+=(--enablerepo "${BASH_REMATCH[1]}")
    done < "${work_dir}/repos.d/el8.repo"

    if [[ ${#enable_repos[@]} -eq 0 ]]; then
        log_warn "  No repo sections found in leapp repo file — skipping bootstrap."
        return 0
    fi

    local dnf_log="${LOG_DIR}/host_dnf_bootstrap_${START_TIME}.log"
    log_info "  Repos: ${enable_repos[*]}"
    log_info "  Log: $dnf_log"
    log_info "  (This may take 3-5 minutes — downloading EL8 bootstrap packages)"

    # Run the same install leapp's actor runs, from host
    dnf install -y \
        --config="${work_dir}/dnf.conf" \
        --setopt="module_platform_id=platform:el8" \
        --setopt="keepcache=1" \
        --releasever="8.10" \
        --installroot="$installroot" \
        --disablerepo="*" \
        "${enable_repos[@]+"${enable_repos[@]}"}" \
        dnf util-linux "dnf-command(config-manager)" \
        2>&1 | tee "$dnf_log" || true

    if [[ -f "${installroot}/usr/bin/dnf" ]] || [[ -f "${installroot}/bin/dnf" ]]; then
        log_ok "  EL8 installroot bootstrapped from host. nspawn will skip the download."
    else
        log_warn "  Host bootstrap incomplete. Check: $dnf_log"
        log_warn "  Last 10 lines:"
        tail -10 "$dnf_log" | while read -r l; do log_warn "    $l"; done
    fi
}

# ---------------------------------------------------------------------------
# fix_nspawn_network — comprehensive nspawn remediation
# Applies ALL known fixes in order of least to most invasive.
# ---------------------------------------------------------------------------
# fix_nspawn_network — all-layer nspawn fix
# Layer A: patch leapp actor to add --network-none
# Layer B: prevent systemd from creating isolated network namespace
# Layer C: patch leapp repo files (sslverify=0, gpgcheck=0)
# Layer D: fix machine-id collision
# Layer E: inject host network config into overlay
# Layer F: host-side dnf bootstrap (pre-populate installroot, no network needed)
# ---------------------------------------------------------------------------
fix_nspawn_network() {
    log_info "Applying nspawn remediation (all layers)..."

    # Layers A+B run unconditionally — they prevent future network disruption
    _install_nspawn_wrapper
    _patch_leapp_actor
    _prevent_nspawn_network_namespace

    # Layers C-F need the overlay to exist
    local overlay; overlay=$(_find_overlay)
    if [[ -z "$overlay" ]]; then
        log_info "  Overlay not yet created — layers C-F will run after first preupgrade."
        return 0
    fi
    log_info "  Overlay: $overlay"

    # Layer C: patch leapp repo files
    log_info "  [C] Patching leapp EL8 repo files (sslverify=0, gpgcheck=0)..."
    _patch_leapp_repos

    # Layer D: machine-id collision
    log_info "  [D] Checking machine-id collision..."
    local host_mid; host_mid=$(cat /etc/machine-id 2>/dev/null || echo "x")
    local ov_mid;   ov_mid=$(cat "${overlay}/etc/machine-id" 2>/dev/null || echo "")
    if [[ "$host_mid" == "$ov_mid" ]] && [[ -n "$ov_mid" ]]; then
        local new_id
        new_id=$(od -An -tx1 /dev/urandom 2>/dev/null | head -1 | \
                 tr -d ' \n' | cut -c1-32)
        echo "$new_id" > "${overlay}/etc/machine-id" 2>/dev/null || true
        log_ok "  machine-id collision fixed."
    else
        log_ok "  machine-id OK."
    fi

    # Layer E: inject host network config
    log_info "  [E] Injecting host network config into overlay..."
    mkdir -p "${overlay}/etc/pki/tls/certs" "${overlay}/etc/pki/ca-trust" 2>/dev/null || true
    cp -f /etc/resolv.conf "${overlay}/etc/resolv.conf"                 2>/dev/null || true
    cp -f /etc/hosts       "${overlay}/etc/hosts"                        2>/dev/null || true
    [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] && \
        cp -f /etc/pki/tls/certs/ca-bundle.crt \
              "${overlay}/etc/pki/tls/certs/ca-bundle.crt"               2>/dev/null || true
    [[ -d /etc/pki/ca-trust ]] && \
        cp -rf /etc/pki/ca-trust/. "${overlay}/etc/pki/ca-trust/"        2>/dev/null || true
    log_ok "  Overlay network config injected."

    # Layer F: host-side dnf bootstrap — pre-populate installroot from host
    log_info "  [F] Running host-side EL8 bootstrap (pre-populates installroot)..."
    _host_dnf_bootstrap "$overlay"

    log_ok "nspawn remediation complete (all layers applied)."
}

phase_fix_inhibitors() {
    log_section "Phase 4b: Universal Inhibitor Remediation"

    # Steps 1-3 run unconditionally on EVERY call (idempotent, cheap).
    # Critical: these must run even when resuming from a saved state.

    # Step 1: Neutralize subscription-manager completely.
    # leapp's target_userspace_creator actor tries to call subscription-manager
    # inside the nspawn container. We use 3 layers:
    #   a) Remove all sub-mgr packages
    #   b) Stub the binary to return 0 silently if removal fails
    #   c) LEAPP_NO_RHSM=1 env var on all leapp commands
    log_info "Step 1: Neutralizing subscription-manager..."
    export LEAPP_NO_RHSM=1

    # Layer a: Remove sub-mgr and related packages
    local _smpkgs
    _smpkgs=$(rpm -qa 2>/dev/null | grep -E \
        "^(subscription-manager|python-syspurpose|python3-syspurpose)" || true)
    if [[ -n "$_smpkgs" ]]; then
        log_info "  Removing packages: $(echo "$_smpkgs" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        yum remove -y --setopt=clean_requirements_on_remove=0 \
            $( echo "$_smpkgs" | tr '\n' ' ' ) 2>/dev/null | tail -3 || true
        # rpm force if yum couldn't do it
        while IFS= read -r _pkg; do
            [[ -z "$_pkg" ]] && continue
            rpm -q "$_pkg" &>/dev/null 2>&1 && \
                rpm -e --nodeps "$_pkg" 2>/dev/null || true
        done <<< "$_smpkgs"
    fi

    # Layer b: Stub binary if still present
    local _smbin
    _smbin=$(command -v subscription-manager 2>/dev/null || echo "")
    if [[ -n "$_smbin" ]] && [[ -f "$_smbin" ]]; then
        if ! grep -q "EL8MIGRATE" "$_smbin" 2>/dev/null; then
            cp -f "$_smbin" "${_smbin}.el8migrate.real" 2>/dev/null || true
            printf "#!/bin/sh\n# EL8MIGRATE\nexit 0\n" > "$_smbin" 2>/dev/null || true
            chmod +x "$_smbin" 2>/dev/null || true
            log_ok "  subscription-manager stubbed (returns 0)."
        else
            log_ok "  subscription-manager already stubbed."
        fi
    else
        log_ok "  subscription-manager not present."
    fi

    # Step 2: Write leapp answerfile (overwrite — no duplicates).
    log_info "Step 2: Writing leapp answerfile..."
    mkdir -p /var/log/leapp 2>/dev/null || true
    cat > /var/log/leapp/answerfile << 'ANSEOF'
[remove_pam_pkcs11_module_check]
confirm = True

[authselect_check]
confirm = True

[remove_ifcfg_files_check]
confirm = True

[grub_enableos_prober_check]
confirm = True

[verify_check_results]
confirm = True

[modified_files_check]
confirm = True

[check_custom_actors]
confirm = True
ANSEOF
    log_ok "  Answerfile written: /var/log/leapp/answerfile"
    # Belt-and-suspenders: also use leapp answer command
    if [[ -n "${LEAPP_BIN:-}" ]]; then
        for ans in \
            "remove_pam_pkcs11_module_check.confirm=True" \
            "authselect_check.confirm=True" \
            "verify_check_results.confirm=True" \
            "modified_files_check.confirm=True"
        do
            "$LEAPP_BIN" answer --section "$ans" 2>/dev/null || true
        done
    fi

    # Step 3: Remove .orig backup files (leapp flags as custom actors)
    log_info "Step 3: Removing .orig backup files..."
    find /usr/share/leapp-repository/ \( -name "*.el8migrate.orig" -o -name "*.orig" \) \
        -delete 2>/dev/null || true
    log_ok "  .orig backups removed."

    # Step 4: Dynamically blacklist drivers from leapp report
    log_info "Step 4: Blacklisting removed drivers from leapp report..."
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
# Phase 5: leapp preupgrade (with auto-retry + nspawn bypass)
# ---------------------------------------------------------------------------
phase_preupgrade() {
    log_section "Phase 5/6: leapp preupgrade (DRY RUN)"

    if [[ "$(state_get PHASE_PREUPGRADE)" == "complete" ]]; then
        log_ok "preupgrade already passed — skipping."; return 0
    fi

    log_info "This is a DRY RUN — no changes are made to the system."

    # Apply layers A+B BEFORE the first preupgrade run.
    # These prevent nspawn from stealing the host NIC — must happen before
    # leapp ever spawns a container, not after the NIC is already gone.
    log_info "Pre-flight: patching nspawn to prevent host network disruption..."
    _install_nspawn_wrapper
    _patch_leapp_actor
    _prevent_nspawn_network_namespace

    # Record the primary NIC NOW before leapp runs — this is the authoritative
    # source for _restore_network and the watchdog to use.
    PRIMARY_NIC=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
    if [[ -z "$PRIMARY_NIC" ]]; then
        PRIMARY_NIC=$(_find_primary_nic)
    fi
    export PRIMARY_NIC

    # Start a background NIC watchdog ONLY if we know the real NIC.
    # The watchdog uses NM (not dhclient) to avoid competing with existing DHCP.
    # It only acts if the interface actually goes DOWN — not just missing route.
    local WATCHDOG_PID=""
    if [[ -n "$PRIMARY_NIC" ]]; then
        log_info "Primary NIC: $PRIMARY_NIC — starting watchdog..."
        (
            local nic="$PRIMARY_NIC"
            while true; do
                sleep 5
                # Check if NIC went DOWN (link state, not just missing route)
                if ip link show "$nic" 2>/dev/null | grep -q "state DOWN\|NO-CARRIER"; then
                    echo "[watchdog $(date '+%H:%M:%S')] $nic is DOWN — restoring link..." \
                        >> "${LOG_FILE:-/tmp/el8migrate.log}" 2>/dev/null || true
                    ip link set "$nic" up 2>/dev/null || true
                    sleep 2
                    # Use NM if available — it manages DHCP cleanly
                    if command -v nmcli &>/dev/null 2>&1; then
                        nmcli device connect "$nic" 2>/dev/null || true
                    fi
                fi
            done
        ) &
        WATCHDOG_PID=$!
        log_info "NIC watchdog PID $WATCHDOG_PID (monitors $PRIMARY_NIC)."
    else
        log_warn "Could not determine primary NIC — watchdog not started."
    fi

    local max_attempts=4
    local attempt=0
    local nspawn_fixed=false

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true
        log_info "leapp preupgrade — attempt $attempt/$max_attempts..."

        # Always re-run inhibitor fixes before each attempt.
        # This ensures subscription-manager removal and answerfile are current.
        state_set "PHASE_INHIBITORS" ""
        phase_fix_inhibitors

        # Verify network is up before each attempt
        _restore_network

        local plog="${LOG_DIR}/leapp_preupgrade_${START_TIME}_attempt${attempt}.log"
        LEAPP_NO_RHSM=1 "$LEAPP_BIN" preupgrade --no-rhsm 2>&1 | tee "$plog" || true

        # ALWAYS restore network after preupgrade — nspawn may have taken it down
        log_info "Checking host network after preupgrade run..."
        _restore_network

        if [[ ! -f /var/log/leapp/leapp-report.txt ]]; then
            log_error "leapp report not generated. See: $plog"
            die "leapp preupgrade failed to produce a report."
        fi

        cp /var/log/leapp/leapp-report.txt \
           "${LOG_DIR}/leapp_report_${START_TIME}_attempt${attempt}.txt"

        # Count hard blockers
        local inhibitor_count error_count
        inhibitor_count=$(grep -c "^Risk Factor: high (error)" \
            /var/log/leapp/leapp-report.txt 2>/dev/null || echo "0")
        error_count=$(grep -c "Following errors occurred" \
            /var/log/leapp/leapp-report.txt 2>/dev/null || echo "0")

        if [[ "$inhibitor_count" -eq 0 ]] && [[ "$error_count" -eq 0 ]]; then
            log_ok "leapp preupgrade: CLEAR — 0 inhibitors, 0 errors."
            state_set "PHASE_PREUPGRADE" "complete"
            return 0
        fi

        log_warn "Attempt $attempt: inhibitors=$inhibitor_count errors=$error_count"

        # Detect nspawn "Unable to install RHEL 8 userspace packages" error
        local has_nspawn_error=false
        grep -q "Unable to install RHEL 8 userspace packages" \
            /var/log/leapp/leapp-report.txt 2>/dev/null && has_nspawn_error=true

        if [[ $attempt -lt $max_attempts ]]; then
            if [[ "$has_nspawn_error" == true ]] && [[ "$nspawn_fixed" == false ]]; then
                log_info "── Detected nspawn repo failure → applying full nspawn remediation ──"
                fix_nspawn_network
                nspawn_fixed=true
            else
                log_info "── Running full inhibitor remediation (attempt $attempt) ──"
                state_set "PHASE_INHIBITORS" ""
                phase_fix_inhibitors
            fi
            # Clear stale report and actor state so next run is fresh
            rm -rf /var/lib/leapp/storage 2>/dev/null || true
            rm -f  /var/log/leapp/leapp-report.txt 2>/dev/null || true
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
            echo
            grep -E "^Risk Factor: high|^Title:" /var/log/leapp/leapp-report.txt 2>/dev/null || true
            die "leapp preupgrade blocked after $max_attempts attempts."
        fi
    done

    # Clean up watchdog
    [[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null || true
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

    LEAPP_NO_RHSM=1 "$LEAPP_BIN" upgrade --no-rhsm \
        2>&1 | tee "${LOG_DIR}/leapp_upgrade_${START_TIME}.log" || true

    # Restore network if nspawn took it down during upgrade
    _restore_network

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

    # Restore original systemd-nspawn (remove our wrapper — no longer needed)
    _remove_nspawn_wrapper
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

    # ── Always run these checks regardless of saved state ───────────────────
    # Subscription-manager removal and answerfile must be current on every run.
    log_info "Pre-checks (always run)..."

    # Remove + stub subscription-manager unconditionally
    export LEAPP_NO_RHSM=1
    local _pre_smpkgs
    _pre_smpkgs=$(rpm -qa 2>/dev/null | grep -E \
        "^(subscription-manager|python-syspurpose|python3-syspurpose)" || true)
    if [[ -n "$_pre_smpkgs" ]]; then
        log_info "  Removing: $(echo "$_pre_smpkgs" | tr '\n' ' ')"
        yum remove -y --setopt=clean_requirements_on_remove=0 \
            $(echo "$_pre_smpkgs" | tr '\n' ' ') 2>/dev/null | tail -3 || true
        while IFS= read -r _p; do
            [[ -z "$_p" ]] && continue
            rpm -q "$_p" &>/dev/null 2>&1 && rpm -e --nodeps "$_p" 2>/dev/null || true
        done <<< "$_pre_smpkgs"
    fi
    # Stub if still present
    local _smb; _smb=$(command -v subscription-manager 2>/dev/null || echo "")
    if [[ -n "$_smb" ]] && [[ -f "$_smb" ]] && ! grep -q "EL8MIGRATE" "$_smb" 2>/dev/null; then
        cp -f "$_smb" "${_smb}.el8migrate.real" 2>/dev/null || true
        printf "#!/bin/sh\n# EL8MIGRATE\nexit 0\n" > "$_smb" && chmod +x "$_smb" || true
        log_ok "  subscription-manager stubbed."
    fi

    # Write answerfile unconditionally (overwrite — always fresh)
    mkdir -p /var/log/leapp 2>/dev/null || true
    cat > /var/log/leapp/answerfile << 'ANSEOF'
[remove_pam_pkcs11_module_check]
confirm = True

[authselect_check]
confirm = True

[remove_ifcfg_files_check]
confirm = True

[grub_enableos_prober_check]
confirm = True

[verify_check_results]
confirm = True

[modified_files_check]
confirm = True

[check_custom_actors]
confirm = True
ANSEOF
    log_ok "  Answerfile written."

    # Install nspawn wrapper unconditionally (idempotent)
    _install_nspawn_wrapper
    _prevent_nspawn_network_namespace

    # Remove .orig backups unconditionally
    find /usr/share/leapp-repository/ -name "*.el8migrate.orig" \
        -delete 2>/dev/null || true
    # ────────────────────────────────────────────────────────────────────────

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
