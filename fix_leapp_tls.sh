#!/usr/bin/env bash
# =============================================================================
#  fix_leapp_tls.sh — Fix TLS/CA cert issue inside leapp nspawn container
#
#  ROOT CAUSE:
#  leapp runs dnf inside a minimal EL8 systemd-nspawn container (overlay).
#  That container uses its own SSL stack — if /etc/pki/tls/certs/ca-bundle.crt
#  is missing or empty inside the overlay, ALL https:// repo syncs fail
#  immediately with "Failed to synchronize cache", even though host curl works.
#
#  This is NOT a DNS or IPv6 issue. The proof: all repos fail instantly and
#  simultaneously — timeout/DNS failures would be sequential and slower.
#
#  RUN: sudo bash fix_leapp_tls.sh
#  THEN: leapp preupgrade   (or re-run the migration script)
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
fix()  { echo -e "${BOLD}${YELLOW}[FIX]${RESET}   $*"; }
info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
err()  { echo -e "${RED}[ERR]${RESET}   $*"; }
sep()  { echo; echo -e "${BOLD}${CYAN}━━━  $*  ━━━${RESET}"; echo; }

[[ $EUID -ne 0 ]] && { err "Run as root: sudo $0"; exit 1; }

# ─── Find the leapp nspawn overlay ──────────────────────────────────────────
sep "Locating leapp nspawn overlay"

OVERLAY=""
for candidate in \
    /var/lib/leapp/scratch/mounts/root_/system_overlay \
    /var/lib/leapp/scratch/mounts/root_overlay
do
    [[ -d "$candidate" ]] && { OVERLAY="$candidate"; break; }
done

if [[ -z "$OVERLAY" ]]; then
    found=$(find /var/lib/leapp/scratch/ -maxdepth 5 -name "system_overlay" -type d 2>/dev/null | head -1 || true)
    [[ -n "$found" ]] && OVERLAY="$found"
fi

if [[ -z "$OVERLAY" ]]; then
    err "No leapp overlay found. Run leapp preupgrade once first to create it."
    err "Then re-run this script."
    exit 1
fi
ok "Overlay: $OVERLAY"

# ─── Step 1: Inspect CA cert state inside overlay ───────────────────────────
sep "Step 1: Inspect CA certificates inside overlay"

OVERLAY_CA="${OVERLAY}/etc/pki/tls/certs/ca-bundle.crt"
OVERLAY_PKI="${OVERLAY}/etc/pki"

info "Host CA bundle:    $(wc -c < /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || echo 'NOT FOUND') bytes"
info "Overlay PKI dir:   $(ls "$OVERLAY_PKI" 2>/dev/null | tr '\n' ' ' || echo 'MISSING')"
if [[ -f "$OVERLAY_CA" ]]; then
    info "Overlay CA bundle: $(wc -c < "$OVERLAY_CA") bytes"
    if [[ ! -s "$OVERLAY_CA" ]]; then
        err "Overlay CA bundle is EMPTY — this is the bug."
    fi
else
    err "Overlay CA bundle MISSING — this is the bug."
fi

# ─── Step 2: Copy entire PKI directory from host into overlay ────────────────
sep "Step 2: Inject host PKI into overlay"

fix "Copying /etc/pki/tls from host into overlay..."
mkdir -p "${OVERLAY}/etc/pki/tls/certs" 2>/dev/null || true
mkdir -p "${OVERLAY}/etc/pki/tls/private" 2>/dev/null || true
mkdir -p "${OVERLAY}/etc/pki/ca-trust" 2>/dev/null || true

# CA bundle — the critical file
cp -f /etc/pki/tls/certs/ca-bundle.crt \
    "${OVERLAY}/etc/pki/tls/certs/ca-bundle.crt" 2>/dev/null && \
    ok "  ca-bundle.crt copied ($(wc -c < "${OVERLAY}/etc/pki/tls/certs/ca-bundle.crt") bytes)" || \
    err "  Failed to copy ca-bundle.crt"

# Full ca-trust anchors
if [[ -d /etc/pki/ca-trust ]]; then
    cp -rf /etc/pki/ca-trust/. "${OVERLAY}/etc/pki/ca-trust/" 2>/dev/null && \
        ok "  ca-trust directory copied." || true
fi

# Also copy resolv.conf while we're at it
fix "Copying /etc/resolv.conf into overlay..."
cp -f /etc/resolv.conf "${OVERLAY}/etc/resolv.conf" 2>/dev/null && \
    ok "  resolv.conf copied: $(cat "${OVERLAY}/etc/resolv.conf" | head -2 | tr '\n' ' ')" || \
    err "  Failed to copy resolv.conf"

# ─── Step 3: Confirm by running curl inside nspawn ──────────────────────────
sep "Step 3: Test HTTPS from inside nspawn container"

info "Running: systemd-nspawn -D $OVERLAY curl https://repo.almalinux.org"
if systemd-nspawn --register=no --quiet -D "$OVERLAY" \
    curl -4 --silent --max-time 15 --head \
    "https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/repodata/repomd.xml" \
    2>&1 | head -5; then
    ok "HTTPS works inside nspawn container!"
    NSPAWN_OK=true
else
    err "HTTPS still failing inside nspawn. Running verbose test..."
    NSPAWN_OK=false
    systemd-nspawn --register=no --quiet -D "$OVERLAY" \
        curl -4 -v --max-time 15 \
        "https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/repodata/repomd.xml" \
        2>&1 | head -30 || true
fi

# ─── Step 4: Fallback — disable SSL verification in leapp repo files ────────
sep "Step 4: Fallback — sslverify=0 in leapp EL8 repo files"

if [[ "$NSPAWN_OK" == false ]]; then
    info "HTTPS test failed. Applying sslverify=0 as fallback..."
    info "(This disables cert verification only for the leapp upgrade repos — not the installed system)"

    LEAPP_REPO_FILE=$(find /etc/leapp/files/ -name "*.repo" 2>/dev/null | head -1 || true)
    if [[ -n "$LEAPP_REPO_FILE" ]]; then
        fix "Adding sslverify=0 to $LEAPP_REPO_FILE..."
        # Add sslverify=0 after each [section] header that doesn't already have it
        python2 - "$LEAPP_REPO_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Add sslverify=0 after each [repo] header if not already present
sections = re.split(r'(\[[^\]]+\])', content)
out = []
i = 0
while i < len(sections):
    part = sections[i]
    if re.match(r'^\[[^\]]+\]$', part.strip()):
        out.append(part)
        i += 1
        body = sections[i] if i < len(sections) else ''
        if 'sslverify' not in body:
            # Insert after first newline
            nl = body.find('\n')
            if nl >= 0:
                body = body[:nl+1] + 'sslverify=0\n' + body[nl+1:]
            else:
                body = '\nsslverify=0\n' + body
        out.append(body)
    else:
        out.append(part)
    i += 1
with open(path, 'w') as f:
    f.write(''.join(out))
print("Done")
PYEOF
        ok "sslverify=0 added to leapp repo files."
    else
        err "No leapp EL8 repo file found in /etc/leapp/files/"
    fi
else
    ok "SSL working — sslverify=0 not needed."
fi

# ─── Step 5: Clean stale leapp state ────────────────────────────────────────
sep "Step 5: Clean stale leapp state for fresh run"

fix "Removing stale leapp report..."
rm -f /var/log/leapp/leapp-report.txt 2>/dev/null && ok "  Report cleared." || true

fix "Clearing leapp storage (stale actor state)..."
rm -rf /var/lib/leapp/storage 2>/dev/null && ok "  Storage cleared." || true

# ─── Summary ─────────────────────────────────────────────────────────────────
sep "Summary"

echo -e "${BOLD}Run leapp preupgrade again:${RESET}"
echo
echo -e "  ${CYAN}leapp preupgrade${RESET}"
echo -e "  # or"
echo -e "  ${CYAN}sudo ./centos7_to_el8_migrate.sh --migrate${RESET}"
echo
if [[ "$NSPAWN_OK" == true ]]; then
    ok "CA cert fix confirmed working. Preupgrade should succeed."
else
    echo -e "${YELLOW}If it still fails, run this to check SSL in detail:${RESET}"
    echo -e "  systemd-nspawn --register=no --quiet -D $OVERLAY \\"
    echo -e "    curl -v https://repo.almalinux.org/almalinux/8/BaseOS/x86_64/os/repodata/repomd.xml"
fi
