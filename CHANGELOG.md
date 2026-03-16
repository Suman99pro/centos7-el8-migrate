# Changelog

## [4.2.0] — 2026-03-16

### Added: Full disk image backup and restore

- **`--backup-dev /dev/sdX`** — writes raw `dd` image of all system disks to
  an external block device. Fastest restore method: single `dd` command.

- **`--backup-dir /path`** — writes `gzip`-compressed disk image(s) to any
  directory (NFS, local, USB). Creates `.img.gz`, `.md5` checksum, and
  `.restore.txt` instructions alongside each image.

- **`--backup-only`** — take backup and exit without migrating.

- **`--restore`** — interactive restore wizard. Supports both block device
  and compressed image restore, with MD5 verification before writing.

- **`--skip-backup`** — bypass backup step (not recommended, requires
  explicit confirmation).

- Backup step is now Step 1 in the migration flow, before any system changes.

- Backup metadata file records exact restore commands including `dd` offset
  for multi-disk systems and `grub2-install` commands.

- Banner now shows backup destination and status.

---

## [4.1.0] — 2026-03-15

### Fixed: Two hard leapp blockers

- **Kernel drivers not in RHEL 8:** Now blacklists all 20+ known removed
  drivers proactively in Step 3 (`preupgrade_fixes`). Also parses the leapp
  report for any additional drivers and blacklists those specifically.

- **subscription-manager container mode:** Comprehensive three-layer fix —
  stubs the binary inside the EL8 installroot, writes `manage_repos=0` to
  the installroot's `rhsm.conf`, and patches the leapp actor's `process()`
  method to skip the check when `LEAPP_NO_RHSM=1`.

- **`.orig` backup files flagged as custom actors:** `_auto_fix_inhibitors`
  now removes all `.bak`, `.orig`, and `.el8migrate.*` files from the leapp
  repository after each retry.

- **openssl.cnf and other answerable checks:** Added to answerfile.

---

## [4.0.0] — 2026-03-15

### Complete rewrite — official ELevate procedure

Replaced the v3.x state-machine/menu infrastructure with a clean linear
script that follows the official AlmaLinux ELevate guide step-for-step.

- Six steps matching the official guide exactly
- CentOS 7 EOL repo fix as Step 1 (official AlmaLinux mirror)
- `systemd-nspawn` binary wrapper prevents NIC capture (systemd v219 bug)
- Host-side EL8 installroot bootstrap bypasses nspawn network failure
- NIC watchdog monitors and restores interface during preupgrade

---

## [3.x] — 2026-03-13 to 2026-03-14

Iterative debugging. Multiple fixes for nspawn network, subscription-manager,
and CentOS 7 EOL repos.

---

## [1.0.0–2.0.0] — 2026-03-13

Initial release. Basic automation, Rocky Linux support added.
