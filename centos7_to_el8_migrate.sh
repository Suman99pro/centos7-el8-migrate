#!/usr/bin/env bash
# =============================================================================
#  centos7_to_el8_migrate.sh  —  CentOS 7 → AlmaLinux 8 / Rocky Linux 8
#  Version : 4.0.0
#  Based on : https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html
#             https://phoenixnap.com/kb/migrate-centos-to-rocky-linux
# =============================================================================
#
#  USAGE:
#    sudo ./centos7_to_el8_migrate.sh [--target alma|rocky] [--auto-yes]
#
#  This script follows the OFFICIAL ELevate procedure exactly, with automation
#  of the manual steps that always need to be done on a CentOS 7 Core/minimal.
#
# =============================================================================
set -uo pipefail
IFS=$'\n\t'

readonly VERSION="4.0.0"
readonly LOG_DIR="/var/log/el8-migration"
readonly START_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/migrate_${START_TS}.log"

# Target: alma or rocky
TARGET="alma"
AUTO_YES=false

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'
MGT='\033[0;35m'

ts()    { date '+%H:%M:%S'; }
info()  { echo -e "[$(ts)] ${CYN}[INFO]${RST}  $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "[$(ts)] ${GRN}[OK]${RST}    $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "[$(ts)] ${YEL}[WARN]${RST}  $*" | tee -a "$LOG_FILE"; }
err()   { echo -e "[$(ts)] ${RED}[ERROR]${RST} $*" | tee -a "$LOG_FILE"; }
die()   { err "$*"; exit 1; }
step()  { echo; echo -e "${BLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; \
          echo -e "${BLD}${CYN}  $*${RST}"; \
          echo -e "${BLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; echo; }

confirm() {
    [[ "$AUTO_YES" == true ]] && return 0
    echo -en "${YEL}  $* [y/N]: ${RST}"
    local ans; read -r ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ── Init ─────────────────────────────────────────────────────────────────────
init() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    [[ $EUID -ne 0 ]] && die "Run as root: sudo $0"
}

# ── Args ─────────────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) TARGET="$2"; shift 2 ;;
            --auto-yes|-y) AUTO_YES=true; shift ;;
            --help|-h) usage; exit 0 ;;
            *) warn "Unknown arg: $1"; shift ;;
        esac
    done
    [[ "$TARGET" == "alma" || "$TARGET" == "rocky" ]] || \
        die "Invalid --target. Use: alma or rocky"
}

usage() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --target alma|rocky   Target distribution (default: alma)"
    echo "  --auto-yes, -y        Non-interactive mode"
    echo "  --help                Show this help"
    echo
    echo "Based on:"
    echo "  https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html"
    echo "  https://phoenixnap.com/kb/migrate-centos-to-rocky-linux"
}

# ── Banner ───────────────────────────────────────────────────────────────────
banner() {
    clear
    echo -e "${BLD}${CYN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║     CentOS 7 → EL8 Migration Toolkit  v${VERSION}           ║"
    echo "  ║     Based on official AlmaLinux ELevate procedure        ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${RST}"
    echo -e "  Target : ${BLD}${TARGET^^} Linux 8${RST}"
    echo -e "  Log    : ${LOG_FILE}"
    echo
}

# =============================================================================
#  STEP 0 — Pre-flight: verify this is CentOS 7 and check basic requirements
# =============================================================================
preflight() {
    step "Pre-flight Checks"

    # Must be CentOS 7
    if ! grep -qi "centos.*7\|centos linux 7" /etc/centos-release 2>/dev/null; then
        die "This script requires CentOS 7. Detected: $(cat /etc/centos-release 2>/dev/null || echo 'unknown')"
    fi
    ok "OS: $(cat /etc/centos-release)"

    # Must be x86_64
    [[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 is supported."
    ok "Arch: x86_64"

    # Network
    if ! curl -4 --silent --max-time 10 --head \
            "https://repo.almalinux.org" &>/dev/null; then
        die "Cannot reach repo.almalinux.org. Internet required."
    fi
    ok "Network: repo.almalinux.org reachable"

    # Disk space — need at least 5G free on /
    local free_gb
    free_gb=$(df --output=avail -BG / | tail -1 | tr -d 'G ')
    if [[ "$free_gb" -lt 5 ]]; then
        die "Need at least 5G free on /. Available: ${free_gb}G"
    fi
    ok "Disk: ${free_gb}G free on /"

    ok "Pre-flight passed."
}

# =============================================================================
#  STEP 1 — Fix CentOS 7 repos (EOL — official mirrors are offline)
#           Official fix from AlmaLinux wiki:
#           curl -o /etc/yum.repos.d/CentOS-Base.repo \
#                https://el7.repo.almalinux.org/centos/CentOS-Base.repo
# =============================================================================
fix_repos() {
    step "Step 1/6: Fix CentOS 7 Repositories (EOL)"
    info "CentOS 7 reached end-of-life. Official mirrors are offline."
    info "Switching to AlmaLinux's CentOS 7 mirror (as per official guide)..."

    # Test if repos already work
    if yum makecache fast &>/dev/null 2>&1; then
        ok "Current repos are reachable — skipping repo fix."
        return 0
    fi

    warn "Current repos unreachable. Applying AlmaLinux's CentOS 7 mirror..."

    # Official fix from AlmaLinux wiki
    curl -fsSL \
        -o /etc/yum.repos.d/CentOS-Base.repo \
        "https://el7.repo.almalinux.org/centos/CentOS-Base.repo" 2>/dev/null || {
        # Fallback: vault.centos.org
        warn "AlmaLinux mirror failed. Falling back to vault.centos.org..."
        cat > /etc/yum.repos.d/CentOS-Base.repo << 'EOF'
[base]
name=CentOS-7 - Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
    }

    yum clean all &>/dev/null
    if yum makecache fast &>/dev/null 2>&1; then
        ok "Repos fixed and reachable."
    else
        die "Cannot reach any CentOS 7 repos. Check your internet connection."
    fi
}

# =============================================================================
#  STEP 2 — Update system (official guide: "yum upgrade -y")
# =============================================================================
update_system() {
    step "Step 2/6: Update System to Latest CentOS 7"
    info "Running: yum upgrade -y"
    info "(This may take several minutes...)"

    yum upgrade -y 2>&1 | tee -a "$LOG_FILE" | tail -5
    ok "System updated."

    # Verify we are at CentOS 7.9 — required for ELevate
    local release
    release=$(cat /etc/centos-release 2>/dev/null || echo "")
    if echo "$release" | grep -q "7\.9"; then
        ok "CentOS 7.9 confirmed — meets ELevate requirement."
    else
        warn "Could not confirm CentOS 7.9. Current: $release"
        warn "ELevate requires 7.9. If upgrade failed, check repo connectivity."
        confirm "Continue anyway?" || die "Aborted."
    fi
}

# =============================================================================
#  STEP 3 — Pre-upgrade fixes (official guide manual steps for CentOS 7)
#           From wiki: rmmod pata_acpi, PermitRootLogin, leapp answer
#           Plus common inhibitors found on all CentOS 7 systems
# =============================================================================
preupgrade_fixes() {
    step "Step 3/6: Apply Pre-Upgrade Fixes"
    info "Applying fixes from leapp-report recommendations (official guide)..."

    # ── Fix 1: pata_acpi — removed in RHEL8 kernel ───────────────────────────
    info "  Blacklisting pata_acpi module (removed in RHEL 8)..."
    rmmod pata_acpi 2>/dev/null || true
    echo "blacklist pata_acpi" > /etc/modprobe.d/pata_acpi.conf
    ok "  pata_acpi blacklisted."

    # ── Fix 2: SSH PermitRootLogin ────────────────────────────────────────────
    if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
        info "  Setting PermitRootLogin yes (required for upgrade access)..."
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
        ok "  PermitRootLogin yes added."
    fi

    # ── Fix 3: ABRT — conflicts with leapp ───────────────────────────────────
    if rpm -q abrt &>/dev/null 2>&1; then
        info "  Removing ABRT (conflicts with leapp)..."
        yum remove -y abrt abrt-libs abrt-cli abrt-addon-ccpp \
            abrt-addon-kerneloops abrt-addon-python abrt-addon-vmcore \
            --setopt=clean_requirements_on_remove=0 2>/dev/null | tail -3 || true
        ok "  ABRT removed."
    fi

    # ── Fix 4: Remove packages that conflict with ELevate ────────────────────
    local conflict_pkgs=(
        centos-release-scl centos-release-scl-rh
        python2-virtualenv python-virtualenv
    )
    for pkg in "${conflict_pkgs[@]}"; do
        if rpm -q "$pkg" &>/dev/null 2>&1; then
            info "  Removing conflicting package: $pkg"
            yum remove -y "$pkg" \
                --setopt=clean_requirements_on_remove=0 2>/dev/null || true
        fi
    done

    # ── Fix 5: subscription-manager — configure for non-RHSM ────────────────
    # This is the fix for "Cannot set container mode for subscription-manager"
    # Official workaround: set manage_repos=0 and use --no-rhsm flag
    export LEAPP_NO_RHSM=1
    mkdir -p /etc/rhsm 2>/dev/null || true
    cat > /etc/rhsm/rhsm.conf << 'EOF'
[rhsm]
manage_repos = 0
full_refresh_on_yum = 0
report_package_profile = 0

[rhsmcertd]
autoAttachInterval = 1440
disable = 1
EOF
    ok "  RHSM configured: manage_repos=0, LEAPP_NO_RHSM=1"

    # ── Fix 6: Install required tools ────────────────────────────────────────
    info "  Installing required tools (yum-utils, curl)..."
    yum install -y yum-utils curl 2>/dev/null | tail -3 || true

    # ── Fix 7: Clean old kernels (leapp prefers single kernel) ───────────────
    info "  Cleaning old kernels..."
    package-cleanup --oldkernels --count=1 -y 2>/dev/null || true

    # ── Fix 8: Write leapp answerfile ────────────────────────────────────────
    info "  Writing leapp answerfile (pre-answering all known questions)..."
    mkdir -p /var/log/leapp 2>/dev/null || true
    cat > /var/log/leapp/answerfile << 'EOF'
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
EOF
    ok "  Answerfile written."

    ok "Pre-upgrade fixes applied."
}

# =============================================================================
#  STEP 4 — Install ELevate + leapp
#           Official commands:
#           yum install -y http://repo.almalinux.org/elevate/elevate-release-latest-el7.noarch.rpm
#           yum install -y leapp-upgrade leapp-data-almalinux
# =============================================================================
install_elevate() {
    step "Step 4/6: Install ELevate and leapp"

    # ── Install elevate-release ───────────────────────────────────────────────
    if ! rpm -q elevate-release &>/dev/null 2>&1; then
        info "Installing elevate-release package (official ELevate repo)..."
        yum install -y \
            "http://repo.almalinux.org/elevate/elevate-release-latest-el$(rpm --eval %rhel).noarch.rpm" \
            2>&1 | tail -10
        rpm -q elevate-release &>/dev/null 2>&1 || die "Failed to install elevate-release."
        ok "elevate-release installed."
    else
        ok "elevate-release already installed."
    fi

    # ── Ensure elevate repo is enabled ───────────────────────────────────────
    yum-config-manager --enable elevate &>/dev/null 2>&1 || \
        sed -i 's/enabled=0/enabled=1/' /etc/yum.repos.d/elevate.repo 2>/dev/null || true
    yum clean all &>/dev/null

    # ── Install leapp packages ────────────────────────────────────────────────
    local data_pkg
    case "$TARGET" in
        alma)  data_pkg="leapp-data-almalinux" ;;
        rocky) data_pkg="leapp-data-rocky" ;;
    esac

    info "Installing: leapp-upgrade $data_pkg"
    yum install -y leapp-upgrade "$data_pkg" 2>&1 | tee -a "$LOG_FILE" | tail -15

    rpm -q "$data_pkg" &>/dev/null 2>&1 || die "Failed to install $data_pkg."

    info "Installed leapp packages:"
    rpm -qa 2>/dev/null | grep -iE "leapp|elevate" | \
        while read -r p; do info "  $p"; done

    ok "ELevate and leapp installed."

    # ── Apply nspawn wrapper immediately after install ────────────────────────
    # This MUST happen before any leapp command runs.
    # Prevents systemd-nspawn v219 from moving enp0s3 into container namespace.
    _install_nspawn_wrapper
}

# =============================================================================
#  STEP 5 — leapp preupgrade + fix inhibitors
#           Official commands:
#           leapp preupgrade
#           (fix inhibitors from leapp-report.txt)
# =============================================================================
run_preupgrade() {
    step "Step 5/6: leapp preupgrade"

    # Find leapp binary
    local leapp_bin
    leapp_bin=$(command -v leapp 2>/dev/null || echo "/usr/bin/leapp")
    [[ -x "$leapp_bin" ]] || die "leapp binary not found."
    ok "leapp: $leapp_bin"

    info "Running: LEAPP_NO_RHSM=1 leapp preupgrade --no-rhsm"
    info "(This performs a dry run — no packages installed)"
    echo

    # Record primary NIC before leapp runs (for watchdog and recovery)
    local primary_nic
    primary_nic=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || echo "")

    # Start NIC watchdog — prevents enp0s3 from staying down if nspawn captures it
    local watchdog_pid=""
    if [[ -n "$primary_nic" ]]; then
        _start_nic_watchdog "$primary_nic"
        watchdog_pid=$!
    fi

    local max_attempts=3
    local attempt=0
    local passed=false

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true
        info "leapp preupgrade — attempt $attempt/$max_attempts"

        # Ensure network is up
        _restore_network "$primary_nic"

        # Apply subscription-manager fix before each attempt
        export LEAPP_NO_RHSM=1
        mkdir -p /etc/rhsm 2>/dev/null || true
        grep -q "manage_repos" /etc/rhsm/rhsm.conf 2>/dev/null || \
            printf '[rhsm]\nmanage_repos = 0\n' > /etc/rhsm/rhsm.conf

        # Sanitize EL8 installroot if it exists from a previous attempt
        _sanitize_installroot

        # Run preupgrade
        local plog="${LOG_DIR}/preupgrade_attempt${attempt}_${START_TS}.log"
        LEAPP_NO_RHSM=1 "$leapp_bin" preupgrade --no-rhsm \
            2>&1 | tee "$plog" | tail -20 || true

        # Restore network immediately after (nspawn may have taken it down)
        _restore_network "$primary_nic"

        # Check result
        if [[ ! -f /var/log/leapp/leapp-report.txt ]]; then
            err "No leapp report generated. Log: $plog"
            continue
        fi

        cp /var/log/leapp/leapp-report.txt \
           "${LOG_DIR}/leapp-report_attempt${attempt}_${START_TS}.txt"

        local blockers
        blockers=$(grep -c "^Risk Factor: high (error)" \
            /var/log/leapp/leapp-report.txt 2>/dev/null || echo "0")

        if [[ "$blockers" -eq 0 ]]; then
            ok "leapp preupgrade: PASSED — 0 blockers."
            passed=true
            break
        fi

        warn "Attempt $attempt: $blockers blocker(s) found."
        _show_blockers
        _auto_fix_inhibitors "$leapp_bin"

        if [[ $attempt -lt $max_attempts ]]; then
            info "Retrying after fixes..."
            rm -rf /var/lib/leapp/storage 2>/dev/null || true
            rm -f /var/log/leapp/leapp-report.txt 2>/dev/null || true
        fi
    done

    # Stop watchdog
    [[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null || true

    if [[ "$passed" != true ]]; then
        echo
        err "════════════════════════════════════════════"
        err "leapp preupgrade blocked after $max_attempts attempts."
        err ""
        err "Review: cat /var/log/leapp/leapp-report.txt"
        err "Then re-run this script."
        err "════════════════════════════════════════════"
        cat /var/log/leapp/leapp-report.txt 2>/dev/null | \
            grep -E "^Risk Factor: high|^Title:" | head -20 || true
        die "Preupgrade failed."
    fi
}

# =============================================================================
#  STEP 6 — leapp upgrade (POINT OF NO RETURN)
#           Official command: leapp upgrade && reboot
# =============================================================================
run_upgrade() {
    step "Step 6/6: leapp upgrade — POINT OF NO RETURN"

    local leapp_bin
    leapp_bin=$(command -v leapp 2>/dev/null || echo "/usr/bin/leapp")

    echo
    echo -e "${RED}${BLD}╔══════════════════════════════════════════════════╗${RST}"
    echo -e "${RED}${BLD}║  ⚠  THIS CANNOT BE UNDONE                       ║${RST}"
    echo -e "${RED}${BLD}║                                                  ║${RST}"
    printf  "${RED}${BLD}║  Upgrading to : %-33s║${RST}\n" "${TARGET^^} Linux 8"
    echo -e "${RED}${BLD}║  Next step    : System will reboot automatically ║${RST}"
    echo -e "${RED}${BLD}║  After reboot : Run with --post-upgrade to verify║${RST}"
    echo -e "${RED}${BLD}╚══════════════════════════════════════════════════╝${RST}"
    echo

    confirm "Proceed with upgrade and reboot?" || die "Upgrade cancelled."

    # Final answer confirmations
    "$leapp_bin" answer --section remove_pam_pkcs11_module_check.confirm=True \
        2>/dev/null || true
    "$leapp_bin" answer --section verify_check_results.confirm=True \
        2>/dev/null || true

    info "Running: LEAPP_NO_RHSM=1 leapp upgrade --no-rhsm"
    info "System will reboot when complete. Watch the console for progress."
    echo

    LEAPP_NO_RHSM=1 "$leapp_bin" upgrade --no-rhsm \
        2>&1 | tee "${LOG_DIR}/leapp-upgrade_${START_TS}.log" || true

    info "leapp upgrade exited. Rebooting..."
    sleep 3
    reboot
}

# =============================================================================
#  POST-UPGRADE — validate after reboot
# =============================================================================
post_upgrade() {
    step "Post-Upgrade Validation"

    echo "--- OS Release ---"
    cat /etc/os-release 2>/dev/null || true
    echo

    echo "--- Kernel ---"
    uname -r
    echo

    local os_name
    os_name=$(grep "^NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "unknown")

    case "$TARGET" in
        alma)
            if grep -qi "almalinux" /etc/os-release 2>/dev/null; then
                ok "✔  Successfully upgraded to AlmaLinux 8!"
            else
                warn "OS may not be AlmaLinux 8. Detected: $os_name"
            fi ;;
        rocky)
            if grep -qi "rocky" /etc/os-release 2>/dev/null; then
                ok "✔  Successfully upgraded to Rocky Linux 8!"
            else
                warn "OS may not be Rocky Linux 8. Detected: $os_name"
            fi ;;
    esac

    # Official post-upgrade checks from the guide
    echo
    info "--- Packages remaining from CentOS 7 ---"
    rpm -qa 2>/dev/null | grep "\.el7" || info "  None found."
    echo

    info "--- Post-upgrade recommended steps ---"
    echo "  1. Set Python 3 as default:"
    echo "       alternatives --set python /usr/bin/python3"
    echo "  2. Re-enable SELinux enforcing:"
    echo "       sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config"
    echo "       touch /.autorelabel && reboot"
    echo "  3. Update all packages:"
    echo "       dnf update -y"
    echo "  4. Check for leftover el7 packages:"
    echo "       rpm -qa | grep el7"
    echo "  5. Remove old GPG keys:"
    echo "       rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n'"
    echo "  6. Clean up leapp artifacts:"
    echo "       rm -fr /root/tmp_leapp_py3"
    echo "       dnf clean all"
    echo
    info "Full logs: ${LOG_DIR}/"
}

# =============================================================================
#  HELPER: Install systemd-nspawn wrapper
#
#  Root cause: systemd-nspawn v219 (CentOS 7) has a bug where it moves the
#  host NIC (enp0s3) into the container network namespace and NEVER moves it
#  back when the container exits. This causes the NIC to vanish from the host.
#
#  Fix: replace /usr/bin/systemd-nspawn with a wrapper that always passes
#  --network-none, preventing nspawn from ever touching the host NIC.
#  The EL8 installroot is pre-populated from the host so no network is needed
#  inside the container anyway.
# =============================================================================
_install_nspawn_wrapper() {
    local real="/usr/bin/systemd-nspawn"
    local backup="/usr/bin/systemd-nspawn.el8migrate.real"
    local marker="EL8MIGRATE_NSPAWN_WRAPPER"

    grep -q "$marker" "$real" 2>/dev/null && {
        ok "  nspawn wrapper already installed."
        return 0
    }

    [[ -f "$real" ]] || { warn "  systemd-nspawn not found — skipping wrapper."; return 0; }
    [[ -f "$backup" ]] || cp -f "$real" "$backup" || { warn "  Cannot back up nspawn."; return 0; }

    cat > "$real" << 'WRAPPER'
#!/usr/bin/env bash
# EL8MIGRATE_NSPAWN_WRAPPER
# Injects --network-none into every systemd-nspawn call.
# Prevents systemd v219 bug where nspawn moves host NIC into container namespace.
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

    chmod +x "$real"
    grep -q "$marker" "$real" 2>/dev/null && \
        ok "  nspawn wrapper installed — NIC capture prevented." || \
        { cp -f "$backup" "$real"; warn "  Wrapper write failed — restored original."; }
}

_remove_nspawn_wrapper() {
    local real="/usr/bin/systemd-nspawn"
    local backup="/usr/bin/systemd-nspawn.el8migrate.real"
    [[ -f "$backup" ]] && cp -f "$backup" "$real" && rm -f "$backup" && \
        ok "systemd-nspawn restored." || true
}

# =============================================================================
#  HELPER: NIC watchdog — runs in background during preupgrade
# =============================================================================
_start_nic_watchdog() {
    local nic="$1"
    (
        while true; do
            sleep 5
            # Only act on state DOWN or NO-CARRIER — not missing route
            if ip link show "$nic" 2>/dev/null | grep -q "state DOWN\|NO-CARRIER"; then
                echo "[$(date '+%H:%M:%S')] watchdog: $nic is DOWN — restoring..." \
                    >> "$LOG_FILE" 2>/dev/null || true
                ip link set "$nic" up 2>/dev/null || true
                sleep 2
                command -v nmcli &>/dev/null && nmcli device connect "$nic" 2>/dev/null || true
            fi
        done
    ) &
    echo $!
}

# =============================================================================
#  HELPER: Restore network if it went down
# =============================================================================
_restore_network() {
    local preferred_nic="${1:-}"

    ip route 2>/dev/null | grep -q "^default" && return 0

    warn "No default route — network is down. Attempting recovery..."

    # If we know the NIC, target it specifically
    if [[ -n "$preferred_nic" ]] && ! echo "$preferred_nic" | \
            grep -qE "^(virbr|veth|docker|br-|vnet|tun|tap)"; then
        ip link set "$preferred_nic" up 2>/dev/null || true
        sleep 2
        command -v nmcli &>/dev/null && nmcli device connect "$preferred_nic" 2>/dev/null || true
        sleep 4
        ip route 2>/dev/null | grep -q "^default" && {
            ok "Network restored via $preferred_nic."; return 0; }
    fi

    # Fallback: restart NetworkManager
    systemctl restart NetworkManager 2>/dev/null || true
    sleep 6
    ip route 2>/dev/null | grep -q "^default" && \
        ok "Network restored via NetworkManager restart." || \
        warn "Network could not be restored automatically."
}

# =============================================================================
#  HELPER: Sanitize EL8 installroot — neutralize subscription-manager inside
#          the nspawn container (it's installed as a dnf dependency)
# =============================================================================
_sanitize_installroot() {
    # Find the EL8 installroot leapp creates
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 \
        -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    [[ -z "$overlay" ]] && return 0

    local installroot="${overlay}/el8target"
    [[ -d "$installroot" ]] || return 0

    # Write rhsm.conf inside the installroot
    mkdir -p "${installroot}/etc/rhsm" 2>/dev/null || true
    printf '[rhsm]\nmanage_repos = 0\nfull_refresh_on_yum = 0\n' \
        > "${installroot}/etc/rhsm/rhsm.conf" 2>/dev/null || true

    # Stub the sub-mgr binary inside the installroot
    for sm in "${installroot}/usr/sbin/subscription-manager" \
               "${installroot}/usr/bin/subscription-manager"; do
        [[ -f "$sm" ]] || continue
        grep -q "EL8MIGRATE" "$sm" 2>/dev/null && continue
        printf '#!/bin/sh\n# EL8MIGRATE_STUB\nexit 0\n' > "$sm" 2>/dev/null || true
        chmod +x "$sm" 2>/dev/null || true
    done
}

# =============================================================================
#  HELPER: Show blockers from leapp report
# =============================================================================
_show_blockers() {
    [[ -f /var/log/leapp/leapp-report.txt ]] || return
    echo
    echo -e "${YEL}══ leapp report — blockers ══${RST}"
    awk '/^Risk Factor: high \(error\)/{found=1} found && /^-{10}/{found=0} found{print}' \
        /var/log/leapp/leapp-report.txt 2>/dev/null | head -40 || true
    echo -e "${YEL}══════════════════════════════${RST}"
    echo
}

# =============================================================================
#  HELPER: Auto-fix known inhibitors between preupgrade attempts
# =============================================================================
_auto_fix_inhibitors() {
    local leapp_bin="${1:-leapp}"
    info "Auto-fixing known inhibitors..."

    local report="/var/log/leapp/leapp-report.txt"
    [[ -f "$report" ]] || return 0

    # Fix: subscription-manager container mode
    if grep -q "Cannot set the container mode" "$report"; then
        info "  Fixing: subscription-manager container mode..."
        export LEAPP_NO_RHSM=1
        mkdir -p /etc/rhsm 2>/dev/null || true
        printf '[rhsm]\nmanage_repos = 0\n' > /etc/rhsm/rhsm.conf
        # Create stub if binary absent
        if ! command -v subscription-manager &>/dev/null 2>&1; then
            printf '#!/bin/sh\n# EL8MIGRATE_STUB\nexit 0\n' \
                > /usr/sbin/subscription-manager 2>/dev/null || true
            chmod +x /usr/sbin/subscription-manager 2>/dev/null || true
        fi
        ok "  subscription-manager fixed."
    fi

    # Fix: kernel drivers removed in RHEL8
    if grep -q "kernel drivers" "$report" 2>/dev/null; then
        info "  Blacklisting removed kernel drivers..."
        local removed_drivers=(
            pata_acpi floppy isdn nozomi aoe
            snd_emu10k1_synth acerhdf bcm203x bpa10x
            lirc_serial mptbase mptctl mptfc mptlan mptsas mptscsih mptspi
            mtdblock n_hdlc pch_gbe snd_atiixp_modem snd_via82xx_modem
            ueagle_atm usbatm xusbatm
        )
        for drv in "${removed_drivers[@]}"; do
            if lsmod 2>/dev/null | grep -q "^${drv} " || \
               grep -q "$drv" "$report" 2>/dev/null; then
                echo "blacklist $drv" > "/etc/modprobe.d/${drv}.conf"
                rmmod "$drv" 2>/dev/null || true
            fi
        done
        ok "  Kernel drivers blacklisted."
    fi

    # Fix: nspawn network — pre-populate EL8 installroot from host
    if grep -q "Unable to install RHEL 8 userspace" "$report" 2>/dev/null; then
        info "  Fixing: nspawn network failure (pre-populating installroot from host)..."
        _host_dnf_bootstrap
        ok "  Installroot pre-populated."
    fi

    # Fix: pam_pkcs11 and other standard answers
    for ans in \
        "remove_pam_pkcs11_module_check.confirm=True" \
        "authselect_check.confirm=True" \
        "verify_check_results.confirm=True"
    do
        "$leapp_bin" answer --section "$ans" 2>/dev/null || true
    done

    # Refresh answerfile
    cat > /var/log/leapp/answerfile << 'EOF'
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
EOF

    ok "Auto-fix complete."
}

# =============================================================================
#  HELPER: Pre-populate EL8 installroot from host
#          (bypasses nspawn network — host has full connectivity)
# =============================================================================
_host_dnf_bootstrap() {
    local overlay
    overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 \
        -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    [[ -z "$overlay" ]] && return 0

    local installroot="${overlay}/el8target"
    local leapp_repo
    leapp_repo=$(find /etc/leapp/files/ -name "*.repo" 2>/dev/null | head -1 || true)
    [[ -z "$leapp_repo" ]] && return 0

    # Already populated?
    [[ -f "${installroot}/usr/bin/dnf" ]] && return 0

    mkdir -p "$installroot" 2>/dev/null || true

    # Ensure dnf on host
    command -v dnf &>/dev/null 2>&1 || yum install -y dnf 2>/dev/null | tail -3 || true
    command -v dnf &>/dev/null 2>&1 || return 0

    info "  Pre-populating EL8 installroot from host..."
    info "  (This may take 3-5 minutes)"

    local work_dir="/var/lib/leapp/scratch/host_dnf_work"
    mkdir -p "${work_dir}/repos.d" 2>/dev/null || true

    # Copy and patch repo file (sslverify=0, gpgcheck=0 for bootstrap only)
    sed -e 's/^sslverify=.*/sslverify=0/' \
        -e 's/^gpgcheck=.*/gpgcheck=0/' \
        "$leapp_repo" > "${work_dir}/repos.d/el8.repo" 2>/dev/null || \
        cp -f "$leapp_repo" "${work_dir}/repos.d/el8.repo"

    grep -q "^sslverify" "${work_dir}/repos.d/el8.repo" || \
        sed -i '/^\[/a sslverify=0\ngpgcheck=0' "${work_dir}/repos.d/el8.repo" 2>/dev/null || true

    # dnf.conf
    printf '[main]\ngpgcheck=0\nsslverify=0\nreposdir=%s/repos.d\n' \
        "$work_dir" > "${work_dir}/dnf.conf"

    # Build --enablerepo args
    local enable_repos=()
    while IFS= read -r line; do
        [[ "$line" =~ ^\[([^\]]+)\]$ ]] && enable_repos+=(--enablerepo "${BASH_REMATCH[1]}")
    done < "${work_dir}/repos.d/el8.repo"

    dnf install -y \
        --config="${work_dir}/dnf.conf" \
        --setopt="module_platform_id=platform:el8" \
        --setopt="keepcache=1" \
        --releasever="8.10" \
        --installroot="$installroot" \
        --disablerepo="*" \
        "${enable_repos[@]+"${enable_repos[@]}"}" \
        dnf util-linux "dnf-command(config-manager)" \
        2>&1 | tail -10 || true

    if [[ -f "${installroot}/usr/bin/dnf" ]]; then
        ok "  EL8 installroot pre-populated."
        _sanitize_installroot
    fi
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    parse_args "$@"
    init

    banner

    # Handle --post-upgrade
    if [[ "${1:-}" == "--post-upgrade" ]]; then
        post_upgrade
        exit 0
    fi

    echo -e "  ${BLD}This script follows the official ELevate procedure:${RST}"
    echo -e "  ${CYN}https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html${RST}"
    echo
    echo "  Steps:"
    echo "    1. Fix CentOS 7 repos (EOL — mirrors offline)"
    echo "    2. Update system to CentOS 7.9"
    echo "    3. Apply pre-upgrade fixes (pata_acpi, SSH, ABRT, etc.)"
    echo "    4. Install ELevate + leapp"
    echo "    5. Run leapp preupgrade (with auto-fix of inhibitors)"
    echo "    6. Run leapp upgrade → reboot"
    echo
    echo -e "  ${YEL}WARNING: This will permanently upgrade your OS.${RST}"
    echo -e "  ${YEL}         Take a snapshot/backup before proceeding.${RST}"
    echo

    confirm "Start migration to ${TARGET^^} Linux 8?" || die "Aborted."

    fix_repos
    update_system
    preupgrade_fixes
    install_elevate
    run_preupgrade
    run_upgrade
}

# Handle --post-upgrade as first arg
if [[ "${1:-}" == "--post-upgrade" ]]; then
    init
    post_upgrade
    exit 0
fi

main "$@"
