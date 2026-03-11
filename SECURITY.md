# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 2.0.x | ✅ Active support |
| 1.0.x | ❌ End of life |

---

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub Issues.**

If you discover a security issue in this script (for example: a code path that could enable privilege escalation, unintended data exposure, or a command injection risk), please report it privately:

1. Email: `security@YOUR_ORG.example.com`
2. Or open a [GitHub Security Advisory](../../security/advisories/new) (private)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix if known

You will receive an acknowledgement within **72 hours** and a resolution timeline within **7 days**.

---

## Security Design Principles

This script follows these principles to minimise risk:

### 1. Least Privilege Awareness
- Requires `root` — explicitly documents why (package management, disk access)
- No credentials, API keys, or secrets are ever written to log files
- Log files are created with restrictive permissions (`/var/log/el8-migration/`, root-owned)

### 2. Input Validation
- All CLI arguments are validated before use
- Block device paths are validated as actual block devices (`-b` test) before `dd`
- Target distro is validated against an allowlist (`alma` | `rocky`)

### 3. Fail-Safe Defaults
- `set -euo pipefail` — script exits immediately on any error
- Backup size is validated before overwriting destination
- Backup integrity is verified with MD5 before the upgrade proceeds
- CRITICAL/HIGH risk issues prompt for confirmation before continuing

### 4. No Secrets in Logs
- The script never logs passwords, private keys, or authentication tokens
- SSH private key directories (`~/.ssh/`) are not backed up or logged
- `/etc/shadow` contents are never read or echoed

### 5. Transparent Operations
- Every action is logged with a timestamp
- The user is prompted before any destructive operation (backup overwrite, upgrade)
- `--auto-yes` is clearly documented as requiring caution

---

## Known Security Considerations for Users

### During Upgrade
- The upgrade process temporarily disables SELinux enforcement (managed by leapp). This is expected and documented.
- The system will reboot into a special initramfs environment. Ensure console or out-of-band access (IPMI/iDRAC) before starting the upgrade.
- SSH may be temporarily unavailable during the reboot cycle.

### Post-Upgrade
- Review `/etc/ssh/sshd_config` — EL8 has stricter crypto defaults.
- Run `update-crypto-policies --show` and `update-crypto-policies --set DEFAULT` to confirm system crypto policy.
- EL8 disables SHA-1 in many contexts. Old TLS certificates or SSH host keys using SHA-1 may need regeneration.
- SELinux relabelling is recommended post-upgrade: `touch /.autorelabel && reboot`
- Run `dnf update --security` immediately after upgrade to patch any post-upgrade CVEs.

### Backup Security
- The block-device backup (`/dev/sdX`) contains a full unencrypted image of your disk, including any LUKS headers if present.
- Secure the backup device physically or encrypt it after creation.
- The backup device should not be left permanently connected in a production environment.
