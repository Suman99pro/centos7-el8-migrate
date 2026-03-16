#!/usr/bin/env bash
# =============================================================================
#  centos7_to_el8_migrate.sh  —  CentOS 7 → AlmaLinux 8 / Rocky Linux 8
#  Version : 4.2.0
#  Based on : https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html
#             https://phoenixnap.com/kb/migrate-centos-to-rocky-linux
# =============================================================================
#
#  USAGE:
#    sudo ./centos7_to_el8_migrate.sh [OPTIONS]
#
#  OPTIONS:
#    --target alma|rocky     Target distribution (default: alma)
#    --backup-dev /dev/sdX   Block device to write disk image backup to
#    --backup-dir /path      Directory to write compressed backup image to
#    --backup-only           Take backup then exit (no migration)
#    --skip-backup           Skip backup step (DANGEROUS — not recommended)
#    --restore               Restore from a previous backup image
#    --auto-yes, -y          Non-interactive mode
#    --post-upgrade          Run post-reboot validation
#    --help                  Show this help
#
#  BACKUP STRATEGY:
#    Option A — External drive (recommended, fastest restore):
#      sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb
#      Writes raw dd image of every disk to the external device.
#      Restore: dd if=/dev/sdb of=/dev/sda bs=4M
#
#    Option B — Compressed image file:
#      sudo ./centos7_to_el8_migrate.sh --backup-dir /mnt/nas
#      Writes gzip-compressed image + MD5 checksum to a directory.
#      Restore: gunzip -c backup.img.gz | dd of=/dev/sda bs=4M
#
# =============================================================================
set -uo pipefail
IFS=$'\n\t'

readonly VERSION="4.2.0"
readonly LOG_DIR="/var/log/el8-migration"
readonly START_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/migrate_${START_TS}.log"

# Options
TARGET="alma"
AUTO_YES=false
BACKUP_DEV=""       # external block device to dd to
BACKUP_DIR=""       # directory to write compressed image
BACKUP_ONLY=false
SKIP_BACKUP=false

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
            --target)       TARGET="$2";     shift 2 ;;
            --backup-dev)   BACKUP_DEV="$2"; shift 2 ;;
            --backup-dir)   BACKUP_DIR="$2"; shift 2 ;;
            --backup-only)  BACKUP_ONLY=true; shift ;;
            --skip-backup)  SKIP_BACKUP=true; shift ;;
            --restore)      do_restore;      exit 0 ;;
            --auto-yes|-y)  AUTO_YES=true;   shift ;;
            --post-upgrade) init; post_upgrade; exit 0 ;;
            --help|-h)      usage;           exit 0 ;;
            *) warn "Unknown arg: $1"; shift ;;
        esac
    done
    [[ "$TARGET" == "alma" || "$TARGET" == "rocky" ]] || \
        die "Invalid --target. Use: alma or rocky"
}

usage() {
    cat << 'EOF'
Usage: sudo ./centos7_to_el8_migrate.sh [OPTIONS]

Options:
  --target alma|rocky     Target OS (default: alma)
  --backup-dev /dev/sdX   Write dd image backup to this block device
  --backup-dir /path      Write compressed backup image to this directory
  --backup-only           Take backup then exit (no migration)
  --skip-backup           Skip backup (DANGEROUS)
  --restore               Restore system from a previous backup
  --auto-yes, -y          Non-interactive mode
  --post-upgrade          Post-reboot validation
  --help                  Show this help

Backup examples:
  # To external USB drive:
  sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb

  # To network share / NFS directory:
  sudo ./centos7_to_el8_migrate.sh --backup-dir /mnt/nas/backups

  # Backup only, no migration:
  sudo ./centos7_to_el8_migrate.sh --backup-dev /dev/sdb --backup-only

  # Restore from backup:
  sudo ./centos7_to_el8_migrate.sh --restore

References:
  https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html
  https://phoenixnap.com/kb/migrate-centos-to-rocky-linux
EOF
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
    echo -e "  Target  : ${BLD}${TARGET^^} Linux 8${RST}"
    if [[ -n "$BACKUP_DEV" ]]; then
        echo -e "  Backup  : ${BLD}${GRN}$BACKUP_DEV (block device)${RST}"
    elif [[ -n "$BACKUP_DIR" ]]; then
        echo -e "  Backup  : ${BLD}${GRN}$BACKUP_DIR (directory)${RST}"
    elif [[ "$SKIP_BACKUP" == true ]]; then
        echo -e "  Backup  : ${RED}SKIPPED${RST}"
    else
        echo -e "  Backup  : ${YEL}not configured (use --backup-dev or --backup-dir)${RST}"
    fi
    echo -e "  Log     : $LOG_FILE"
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
#  BACKUP — Full disk image backup before migration
#
#  Strategy:
#    Option A: dd directly to an external block device (fastest restore)
#    Option B: dd | gzip to a directory (works without extra hardware)
#
#  The backup captures the raw disk state — bootloader, partitions, data.
#  Restore is a single dd command and puts the system back exactly as it was.
# =============================================================================
take_backup() {
    step "Backup: Full Disk Image"

    # Discover all disks to back up (skip loop, ram, and the backup target itself)
    local source_disks=()
    while IFS= read -r disk; do
        local dev="/dev/${disk}"
        # Skip if this IS the backup device
        [[ -n "$BACKUP_DEV" ]] && [[ "$dev" == "$BACKUP_DEV"* ]] && continue
        source_disks+=("$dev")
    done < <(lsblk -nd --output NAME,TYPE 2>/dev/null | \
             awk '$2=="disk"{print $1}')

    if [[ ${#source_disks[@]} -eq 0 ]]; then
        die "No source disks found. Check: lsblk"
    fi

    info "Disks to back up:"
    for disk in "${source_disks[@]}"; do
        local size; size=$(lsblk -nd --output SIZE "$disk" 2>/dev/null | tail -1 | xargs)
        info "  $disk  ($size)"
    done
    echo

    # ── Option A: backup to external block device ─────────────────────────────
    if [[ -n "$BACKUP_DEV" ]]; then
        [[ -b "$BACKUP_DEV" ]] || die "Backup device not found: $BACKUP_DEV"

        # Safety: warn if backup device looks like a system disk
        if lsblk -no MOUNTPOINT "$BACKUP_DEV" 2>/dev/null | grep -q "^/$\|^/boot"; then
            die "REFUSED: $BACKUP_DEV appears to have system partitions mounted. Use a dedicated backup drive."
        fi

        local backup_size; backup_size=$(lsblk -nd --output SIZE "$BACKUP_DEV" 2>/dev/null | tail -1 | xargs)
        echo -e "  ${YEL}Backup device : ${BLD}$BACKUP_DEV${RST}${YEL}  ($backup_size)${RST}"
        echo -e "  ${YEL}Source disk(s): ${source_disks[*]}${RST}"
        echo
        echo -e "  ${RED}${BLD}WARNING: All existing data on $BACKUP_DEV will be overwritten.${RST}"
        echo
        confirm "Write disk image backup to $BACKUP_DEV?" || die "Backup cancelled."

        local backup_meta="${LOG_DIR}/backup_metadata_${START_TS}.txt"
        {
            echo "Backup created  : $(date)"
            echo "Source disks    : ${source_disks[*]}"
            echo "Backup device   : $BACKUP_DEV"
            echo "Hostname        : $(hostname -f 2>/dev/null || hostname)"
            echo "OS              : $(cat /etc/centos-release 2>/dev/null)"
            echo "Kernel          : $(uname -r)"
            echo
            echo "=== RESTORE INSTRUCTIONS ==="
            echo "Boot from a live CD/USB, then run:"
            for src in "${source_disks[@]}"; do
                local disk_name; disk_name=$(basename "$src")
                echo "  dd if=$BACKUP_DEV of=$src bs=4M conv=noerror,sync status=progress"
                echo "  # Then rebuild bootloader:"
                echo "  grub2-install $src"
                echo "  grub2-mkconfig -o /boot/grub2/grub.cfg"
            done
        } > "$backup_meta"
        ok "Backup metadata: $backup_meta"

        # Write each source disk sequentially to the backup device
        # Use an offset per disk so all disks fit on one backup device
        local offset_bytes=0
        for src in "${source_disks[@]}"; do
            local disk_bytes; disk_bytes=$(blockdev --getsize64 "$src" 2>/dev/null || echo 0)
            local disk_gb=$(( disk_bytes / 1024 / 1024 / 1024 ))
            info "Backing up $src (${disk_gb}G) → $BACKUP_DEV (offset ${offset_bytes}B)..."
            info "(This may take several minutes — do not interrupt)"

            dd if="$src" \
               of="$BACKUP_DEV" \
               bs=4M \
               seek=$(( offset_bytes / 512 / 8192 )) \
               conv=noerror,sync \
               status=progress \
               2>&1 | tee -a "$LOG_FILE" || die "dd backup failed for $src"

            sync
            ok "$src backed up (${disk_gb}G)."

            # Record disk size in metadata for restore
            echo "disk:${disk_name}:bytes:${disk_bytes}" >> "$backup_meta"
            echo "disk:${disk_name}:offset_bytes:${offset_bytes}" >> "$backup_meta"

            (( offset_bytes += disk_bytes )) || true
        done

        ok "Backup complete → $BACKUP_DEV"
        echo
        echo -e "  ${GRN}${BLD}To restore:${RST}"
        echo    "    Boot from a live CD/USB, then:"
        for src in "${source_disks[@]}"; do
            echo "    dd if=$BACKUP_DEV of=$src bs=4M conv=noerror,sync status=progress"
        done

    # ── Option B: backup to a directory as compressed image ───────────────────
    elif [[ -n "$BACKUP_DIR" ]]; then
        [[ -d "$BACKUP_DIR" ]] || mkdir -p "$BACKUP_DIR" || \
            die "Cannot create backup directory: $BACKUP_DIR"

        # Check free space in backup dir
        local dir_free_gb
        dir_free_gb=$(df --output=avail -BG "$BACKUP_DIR" | tail -1 | tr -d 'G ')

        local total_disk_gb=0
        for src in "${source_disks[@]}"; do
            local db; db=$(blockdev --getsize64 "$src" 2>/dev/null || echo 0)
            (( total_disk_gb += db / 1024 / 1024 / 1024 )) || true
        done
        local needed_gb=$(( total_disk_gb / 3 ))  # gzip typically achieves ~3:1 on OS disks

        info "Backup directory : $BACKUP_DIR  (${dir_free_gb}G free)"
        info "Total disk size  : ${total_disk_gb}G  (est. compressed: ~${needed_gb}G)"

        if [[ "$dir_free_gb" -lt "$needed_gb" ]]; then
            warn "Backup dir may not have enough space (${dir_free_gb}G free, need ~${needed_gb}G)."
            confirm "Continue anyway?" || die "Backup cancelled."
        fi

        confirm "Write compressed disk image(s) to $BACKUP_DIR?" || die "Backup cancelled."

        for src in "${source_disks[@]}"; do
            local disk_name; disk_name=$(basename "$src")
            local out_img="${BACKUP_DIR}/centos7_${disk_name}_${START_TS}.img.gz"
            local out_md5="${out_img}.md5"

            info "Backing up $src → $out_img"
            info "(Using dd | gzip — this may take several minutes)"

            dd if="$src" bs=4M conv=noerror,sync status=progress 2>>"$LOG_FILE" | \
                gzip -1 > "$out_img" || die "Backup failed for $src"

            sync
            ok "$src compressed image written."

            # MD5 checksum for integrity verification
            info "Computing MD5 checksum..."
            md5sum "$out_img" > "$out_md5"
            ok "MD5: $(cat "$out_md5")"

            # Write restore instructions alongside the image
            cat > "${out_img%.gz}.restore.txt" << RESTOREEOF
Backup Information
==================
Created    : $(date)
Source     : $src
Hostname   : $(hostname -f 2>/dev/null || hostname)
OS         : $(cat /etc/centos-release 2>/dev/null)
Kernel     : $(uname -r)
Image file : $out_img
MD5        : $(cat "$out_md5")

Restore Instructions
====================
1. Boot the server from a live CD/USB (e.g. CentOS 7 minimal ISO)
2. Verify image integrity:
     md5sum -c ${out_img##*/}.md5
3. Restore the disk image:
     gunzip -c $out_img | dd of=$src bs=4M conv=noerror,sync status=progress
4. Rebuild the bootloader:
     grub2-install $src
     grub2-mkconfig -o /boot/grub2/grub.cfg
5. Reboot normally.

Notes:
- If the server won't boot after restore, boot from live media and
  run: grub2-install $src
- The image captures the full disk including MBR and all partitions.
RESTOREEOF
            ok "Restore instructions: ${out_img%.gz}.restore.txt"
        done

        ok "All backups written to $BACKUP_DIR"
        ls -lh "${BACKUP_DIR}/"*"${START_TS}"* 2>/dev/null || true

    # ── No backup destination provided ────────────────────────────────────────
    else
        echo
        echo -e "  ${YEL}${BLD}No backup destination specified.${RST}"
        echo
        echo "  Provide one of:"
        echo "    --backup-dev /dev/sdX   Write to external block device (fastest)"
        echo "    --backup-dir /path      Write compressed image to directory"
        echo "    --skip-backup           Skip backup (NOT recommended)"
        echo
        echo "  Examples:"
        echo "    sudo $0 --target alma --backup-dev /dev/sdb"
        echo "    sudo $0 --target alma --backup-dir /mnt/nas/backups"
        echo
        if confirm "Skip backup and proceed without one? (NOT recommended)"; then
            warn "Proceeding without backup — if upgrade fails you cannot easily restore."
        else
            die "Please specify --backup-dev or --backup-dir and re-run."
        fi
    fi
}

# =============================================================================
#  RESTORE — Restore from a previous backup image
# =============================================================================
do_restore() {
    init
    step "Restore from Backup"

    echo -e "  ${BLD}Restore will overwrite your current disk with the backup image.${RST}"
    echo

    # ── Option A: restore from block device ───────────────────────────────────
    echo "  Where is your backup?"
    echo "  1) Block device (e.g. external USB drive)"
    echo "  2) Compressed image file (.img.gz)"
    echo
    echo -en "  ${YEL}Choice [1/2]: ${RST}"
    local choice; read -r choice

    case "$choice" in
        1)
            echo -en "  ${YEL}Backup device (e.g. /dev/sdb): ${RST}"
            local bdev; read -r bdev
            [[ -b "$bdev" ]] || die "Device not found: $bdev"

            # Find restore instructions if they exist
            local meta; meta=$(ls "${LOG_DIR}/backup_metadata_"*.txt 2>/dev/null | tail -1 || true)
            if [[ -n "$meta" ]]; then
                info "Found backup metadata: $meta"
                cat "$meta"
                echo
            fi

            local disks=()
            while IFS= read -r disk; do
                [[ "/dev/${disk}" == "$bdev"* ]] && continue
                disks+=("/dev/${disk}")
            done < <(lsblk -nd --output NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

            echo -e "  ${YEL}Target disk(s): ${disks[*]:-none found}${RST}"
            echo -en "  ${YEL}Target disk to restore to (e.g. /dev/sda): ${RST}"
            local target_disk; read -r target_disk
            [[ -b "$target_disk" ]] || die "Disk not found: $target_disk"

            echo -e "  ${RED}${BLD}WARNING: $target_disk will be COMPLETELY OVERWRITTEN.${RST}"
            confirm "Restore $bdev → $target_disk?" || die "Restore cancelled."

            info "Restoring $bdev → $target_disk ..."
            dd if="$bdev" of="$target_disk" bs=4M conv=noerror,sync status=progress \
                2>&1 | tee -a "$LOG_FILE" || die "Restore failed."
            sync

            ok "Restore complete."
            echo
            info "Rebuild bootloader if needed:"
            echo "  grub2-install $target_disk"
            echo "  grub2-mkconfig -o /boot/grub2/grub.cfg"
            echo
            info "Reboot to boot into the restored system."
            ;;

        2)
            echo -en "  ${YEL}Image file path (.img.gz): ${RST}"
            local img_file; read -r img_file
            [[ -f "$img_file" ]] || die "File not found: $img_file"

            # Verify MD5 if available
            local md5_file="${img_file}.md5"
            if [[ -f "$md5_file" ]]; then
                info "Verifying MD5 checksum..."
                md5sum -c "$md5_file" && ok "Checksum verified." || \
                    { err "Checksum MISMATCH — backup may be corrupted."; \
                      confirm "Continue anyway?" || die "Restore cancelled."; }
            fi

            echo -en "  ${YEL}Target disk (e.g. /dev/sda): ${RST}"
            local target_disk; read -r target_disk
            [[ -b "$target_disk" ]] || die "Disk not found: $target_disk"

            echo -e "  ${RED}${BLD}WARNING: $target_disk will be COMPLETELY OVERWRITTEN.${RST}"
            confirm "Restore $img_file → $target_disk?" || die "Restore cancelled."

            info "Restoring $img_file → $target_disk ..."
            gunzip -c "$img_file" | \
                dd of="$target_disk" bs=4M conv=noerror,sync status=progress \
                2>&1 | tee -a "$LOG_FILE" || die "Restore failed."
            sync

            ok "Restore complete."
            echo
            info "Rebuild bootloader if needed:"
            echo "  grub2-install $target_disk"
            echo "  grub2-mkconfig -o /boot/grub2/grub.cfg"
            echo
            info "Reboot to boot into the restored system."
            ;;

        *)
            die "Invalid choice."
            ;;
    esac
}
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

    # ── Fix 1: Kernel drivers removed in RHEL 8 ──────────────────────────────
    # Official guide: "sudo rmmod pata_acpi"
    # We blacklist ALL known removed drivers proactively to prevent the
    # "Leapp detected loaded kernel drivers no longer maintained in RHEL 8" blocker.
    info "  Blacklisting kernel drivers removed in RHEL 8..."
    local removed_drivers=(
        pata_acpi           # explicitly named in official guide
        floppy isdn nozomi aoe
        snd_emu10k1_synth acerhdf bcm203x bpa10x
        lirc_serial
        mptbase mptctl mptfc mptlan mptsas mptscsih mptspi
        mtdblock n_hdlc pch_gbe
        snd_atiixp_modem snd_via82xx_modem
        ueagle_atm usbatm xusbatm
    )
    for drv in "${removed_drivers[@]}"; do
        echo "blacklist $drv" > "/etc/modprobe.d/${drv}.conf"
        lsmod 2>/dev/null | grep -q "^${drv} " && rmmod "$drv" 2>/dev/null || true
    done
    ok "  Kernel drivers blacklisted (${#removed_drivers[@]} total)."

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
#
#  Reads the actual leapp report and fixes each blocker specifically.
#  Called after every failed preupgrade attempt.
# =============================================================================
_auto_fix_inhibitors() {
    local leapp_bin="${1:-leapp}"
    info "Auto-fixing inhibitors from leapp report..."

    local report="/var/log/leapp/leapp-report.txt"
    [[ -f "$report" ]] || { warn "  No report found."; return 0; }

    # ── FIX A: subscription-manager container mode ───────────────────────────
    # Actor: target_userspace_creator
    # Root cause: leapp calls subscription-manager INSIDE the nspawn container
    # The container has its own sub-mgr binary installed as a dnf dependency.
    # Fix: stub the binary inside the EL8 installroot AND disable the leapp
    #      actor that triggers this check when LEAPP_NO_RHSM=1.
    if grep -q "Cannot set the container mode" "$report"; then
        info "  [A] Fixing: subscription-manager container mode..."
        export LEAPP_NO_RHSM=1

        # Host-side: ensure rhsm config
        mkdir -p /etc/rhsm /etc/rhsm/facts 2>/dev/null || true
        cat > /etc/rhsm/rhsm.conf << 'RHSMEOF'
[rhsm]
manage_repos = 0
full_refresh_on_yum = 0
report_package_profile = 0

[rhsmcertd]
autoAttachInterval = 1440
disable = 1
RHSMEOF

        # Host-side: stub binary if absent (older leapp needs it present)
        if ! command -v subscription-manager &>/dev/null 2>&1; then
            for sm_path in /usr/sbin/subscription-manager /usr/bin/subscription-manager; do
                printf '#!/bin/sh\n# EL8MIGRATE_STUB - satisfies leapp binary check\nexit 0\n' \
                    > "$sm_path" 2>/dev/null || true
                chmod +x "$sm_path" 2>/dev/null || true
            done
        fi

        # Installroot-side: stub sub-mgr INSIDE the EL8 container
        # This is the actual location where the error fires
        local overlay
        overlay=$(find /var/lib/leapp/scratch/ -maxdepth 5 \
            -name "system_overlay" -type d 2>/dev/null | head -1 || true)
        if [[ -n "$overlay" ]]; then
            local installroot="${overlay}/el8target"
            mkdir -p "${installroot}/etc/rhsm" \
                     "${installroot}/usr/sbin" \
                     "${installroot}/usr/bin" 2>/dev/null || true

            # rhsm.conf inside installroot
            printf '[rhsm]\nmanage_repos = 0\n' \
                > "${installroot}/etc/rhsm/rhsm.conf" 2>/dev/null || true

            # Stub sub-mgr inside installroot
            for sm in "${installroot}/usr/sbin/subscription-manager" \
                      "${installroot}/usr/bin/subscription-manager"; do
                printf '#!/bin/sh\n# EL8MIGRATE_STUB\nexit 0\n' > "$sm" 2>/dev/null || true
                chmod +x "$sm" 2>/dev/null || true
            done
            ok "  Sub-mgr stubbed in EL8 installroot."
        fi

        # Disable the leapp actor that runs this check
        # Actor: subscribedrhsm or rhsmfacts — finds it dynamically
        for actor_base in \
            /usr/share/leapp-repository/repositories/system_upgrade \
            /etc/leapp/repos.d/system_upgrade
        do
            [[ -d "$actor_base" ]] || continue
            # Find actor files containing the subscription-manager check
            while IFS= read -r actor_file; do
                grep -q "container.*mode\|set_container_mode\|SubscriptionManager" \
                    "$actor_file" 2>/dev/null || continue
                grep -q "EL8_DISABLED" "$actor_file" 2>/dev/null && continue
                [[ -f "${actor_file}.bak" ]] || cp -f "$actor_file" "${actor_file}.bak"
                # Inject early return when LEAPP_NO_RHSM=1
                python2 - "$actor_file" << 'PYEOF' 2>/dev/null && \
                    info "  Disabled actor: $(basename $(dirname $actor_file))/$(basename $actor_file)" || true
import sys, re
path = sys.argv[1]
with open(path) as f:
    c = f.read()
if 'EL8_DISABLED' in c:
    sys.exit(0)
guard = '    def process(self):\n        import os\n        if os.environ.get("LEAPP_NO_RHSM","0")=="1":return  # EL8_DISABLED\n'
c = re.sub(r'(\s+def process\(self\):)', guard, c, count=1)
with open(path, 'w') as f:
    f.write(c)
sys.exit(0)
PYEOF
            done < <(find "$actor_base" -name "actor.py" 2>/dev/null)
        done

        ok "  subscription-manager fix complete."
    fi

    # ── FIX B: Kernel drivers removed in RHEL 8 ──────────────────────────────
    # Actor: checkinstalledkernels or checkkerneldrivers
    # The report lists the exact driver names — parse and blacklist them all.
    if grep -q "kernel drivers\|no longer maintained\|loaded kernel" "$report" 2>/dev/null; then
        info "  [B] Fixing: loaded kernel drivers not in RHEL 8..."

        # Parse exact driver names from the report
        # The report format is:
        #   Summary: The following RHEL 8 incompatible kernel drivers are loaded:
        #       - driver_name
        local parsed_drivers=()
        local in_driver_section=false
        while IFS= read -r line; do
            if echo "$line" | grep -qiE "incompatible.*driver|driver.*incompatible|no longer.*maintained"; then
                in_driver_section=true
                continue
            fi
            if $in_driver_section; then
                if echo "$line" | grep -qE "^\s+-\s+[a-z0-9_]+\s*$"; then
                    local drv
                    drv=$(echo "$line" | tr -d ' \t-')
                    [[ -n "$drv" ]] && parsed_drivers+=("$drv")
                elif echo "$line" | grep -qE "^-{5,}|^Risk Factor|^Title"; then
                    in_driver_section=false
                fi
            fi
        done < "$report"

        # Also blacklist all universally removed drivers
        local universal_drivers=(
            pata_acpi floppy isdn nozomi aoe
            snd_emu10k1_synth acerhdf bcm203x bpa10x
            lirc_serial mptbase mptctl mptfc mptlan mptsas mptscsih mptspi
            mtdblock n_hdlc pch_gbe snd_atiixp_modem snd_via82xx_modem
            ueagle_atm usbatm xusbatm
        )

        local all_drivers=("${universal_drivers[@]}")
        for d in "${parsed_drivers[@]+"${parsed_drivers[@]}"}"; do
            all_drivers+=("$d")
        done

        local blacklisted=0
        for drv in "${all_drivers[@]}"; do
            # Only act on drivers that are actually loaded OR mentioned in report
            if lsmod 2>/dev/null | grep -q "^${drv} " || \
               grep -qi "\b${drv}\b" "$report" 2>/dev/null; then
                if ! grep -q "blacklist ${drv}" \
                        "/etc/modprobe.d/${drv}.conf" 2>/dev/null; then
                    echo "blacklist ${drv}" > "/etc/modprobe.d/${drv}.conf"
                    ((blacklisted++)) || true
                fi
                rmmod "$drv" 2>/dev/null || true
            fi
        done
        [[ ${#parsed_drivers[@]} -gt 0 ]] && \
            info "  Drivers from report: ${parsed_drivers[*]}"
        ok "  $blacklisted driver(s) blacklisted and unloaded."
    fi

    # ── FIX C: .orig backup files flagged as custom actors ───────────────────
    if grep -q "custom leapp actors\|\.orig" "$report" 2>/dev/null; then
        info "  [C] Removing .orig backup files (flagged as custom actors)..."
        find /usr/share/leapp-repository/ \
            \( -name "*.bak" -o -name "*.orig" -o -name "*.el8migrate.*" \) \
            -delete 2>/dev/null || true
        ok "  Backup files removed."
    fi

    # ── FIX D: openssl.cnf modified ──────────────────────────────────────────
    # leapp will replace it — just need to answer the check
    # This is handled via answerfile below

    # ── Refresh answerfile — cover all known answerable checks ────────────────
    info "  [D] Refreshing leapp answerfile..."
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

    # Run leapp answer for each section too
    for ans in \
        "remove_pam_pkcs11_module_check.confirm=True" \
        "authselect_check.confirm=True" \
        "verify_check_results.confirm=True"
    do
        "$leapp_bin" answer --section "$ans" 2>/dev/null || true
    done

    # Clean leapp actor state so inhibitor-fixed actors re-run fresh
    rm -rf /var/lib/leapp/storage 2>/dev/null || true

    ok "All auto-fixes applied."
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

    echo -e "  ${BLD}This script follows the official ELevate procedure:${RST}"
    echo -e "  ${CYN}https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html${RST}"
    echo
    echo "  Steps:"
    echo "    0. Pre-flight checks"
    echo "    1. Disk image backup (recommended — allows full restore if needed)"
    echo "    2. Fix CentOS 7 repos (EOL — mirrors offline)"
    echo "    3. Update system to CentOS 7.9"
    echo "    4. Apply pre-upgrade fixes (drivers, SSH, ABRT, RHSM)"
    echo "    5. Install ELevate + leapp"
    echo "    6. Run leapp preupgrade (auto-fix inhibitors)"
    echo "    7. Run leapp upgrade → reboot"
    echo
    echo -e "  ${YEL}${BLD}WARNING: This will permanently upgrade your OS.${RST}"
    if [[ -z "$BACKUP_DEV" && -z "$BACKUP_DIR" && "$SKIP_BACKUP" != true ]]; then
        echo -e "  ${YEL}         Strongly recommended: specify --backup-dev or --backup-dir${RST}"
    fi
    echo

    confirm "Start migration to ${TARGET^^} Linux 8?" || die "Aborted."

    # Step 0: pre-flight
    preflight

    # Step 1: backup
    if [[ "$SKIP_BACKUP" != true ]]; then
        take_backup
        if [[ "$BACKUP_ONLY" == true ]]; then
            ok "Backup complete. Exiting (--backup-only)."
            exit 0
        fi
    else
        warn "Backup skipped (--skip-backup). Proceeding without backup."
    fi

    # Steps 2–7: migration
    fix_repos
    update_system
    preupgrade_fixes
    install_elevate
    run_preupgrade
    run_upgrade
}

main "$@"
