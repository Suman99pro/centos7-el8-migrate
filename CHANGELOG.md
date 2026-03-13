# Changelog

## [3.0.0] — 2026-03-13

### Complete redesign

**Architecture**
- Removed `set -e` / `set -euo pipefail` global scope — script no longer dies on non-zero exit
- Errors collected into categorised arrays (BLOCK / WARN / AUTO-FIX / INFO / PASS) instead of immediately terminating
- Phase-based execution with state persistence — failed/interrupted migrations resume from last completed phase
- Four distinct modes: `assess`, `fix`, `migrate`, `post-upgrade`
- Interactive main menu with migration progress display

**Assessment phase (new)**
- Completely non-destructive read-only preflight check
- Colour-coded report: ✔ PASS / ℹ INFO / ⚙ AUTO-FIX / ⚠ WARN / ✖ BLOCK
- GO / NO-GO / PROCEED WITH CAUTION verdict
- Exit codes: 0=go, 1=warnings, 2=blockers (CI-friendly)
- Saves report to `/var/log/el8-migration/preflight_report_TIMESTAMP.txt`

**Auto-fix phase (new)**
- Separate `--fix` mode applies only safe, non-destructive remediations
- Also runs automatically before migration if auto-fixable issues found

**Migration wizard**
- Runs preflight first — blocks if any BLOCK findings exist
- Each phase is individually confirmable and resumable
- State saved to `/var/log/el8-migration/.migration_state`

### Bug fixes carried forward from v2.x

- **IPv6**: Detects broken IPv6 and disables via `sysctl` before leapp runs — prevents `Unable to install RHEL 8 userspace packages` error from leapp nspawn repo failures
- **ABRT cascade removal**: Uses `--setopt=clean_requirements_on_remove=0` — prevents yum from cascade-removing `leapp-upgrade-el7toel8` via `libreport` dependency
- **leapp binary resolver**: 6-stage resolver (known paths → PATH → filesystem search → RPM file lists → install provider packages → diagnostic dump)
- **leapp framework package**: Explicitly installs `leapp` RPM (binary provider) separately from `leapp-upgrade-el7toel8` (actors/data provider)
- **leapp repo disabled by default**: Always force-enables the elevate repo after installing elevate-release RPM
- **Rocky Linux EPEL**: Enables CRB repo before EPEL install on Rocky Linux

---

## [2.0.0] — 2026-03-12

- Universal leapp inhibitor remediation engine
- Dynamic driver blacklisting from leapp-report.txt
- leapp answerfile pre-population for all known interactive prompts
- IPv6 detection and disabling (Step 10)
- ABRT safe removal (no autoremove)
- leapp binary resolver (initial version)
- Rocky Linux 8 full support audit

## [1.0.0] — 2026-03-11

- Initial release
- Phase 1–5 migration flow
- DD backup with MD5 verification
- Post-upgrade validation
