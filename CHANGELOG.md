# Changelog

## [4.0.0] — 2026-03-15

### Complete rewrite — based on official ELevate procedure

**Why:** Previous versions (1.x–3.x) accumulated layers of workarounds
that were masking the real issues. This version starts from the official
AlmaLinux ELevate guide and adds only the automations that are genuinely
needed for a CentOS 7 Core/minimal install.

### What changed

- Script now follows official procedure from
  https://wiki.almalinux.org/elevate/ELevating-CentOS7-to-AlmaLinux-10.html
  step for step — no deviation from the documented path

- **CentOS 7 EOL repo fix:** added as Step 1 — official fix from AlmaLinux wiki
  (`curl -o /etc/yum.repos.d/CentOS-Base.repo https://el7.repo.almalinux.org/...`)

- **NIC protection:** `systemd-nspawn` binary wrapper injects `--network-none`
  unconditionally — prevents host NIC from being moved into container namespace
  (systemd v219 bug, confirmed in issue #4330)

- **subscription-manager:** sets `LEAPP_NO_RHSM=1` + `manage_repos=0` in
  `/etc/rhsm/rhsm.conf` + creates stub binary if absent — covers all leapp
  versions including pre-PR#1133 builds that require binary presence

- **EL8 installroot bootstrap:** pre-populates installroot from host when nspawn
  network fails (correct fix, not a workaround)

- **NIC watchdog:** background process restores NIC if it goes DOWN during
  preupgrade — only monitors real NICs, never touches virbr/veth/docker

- Removed all the accumulated complexity from v3.x that was not solving the
  root causes

### Removed
- All the custom assessment/menu/state-machine infrastructure from v3.x
- Multiple duplicate fix functions
- All the ad-hoc workarounds that weren't addressing root causes

---

## [3.x] — 2026-03-13 to 2026-03-14

Iterative debugging session. Multiple attempts to fix:
- nspawn network failures (python regex patching — unreliable)
- subscription-manager (removal approach — wrong)
- CentOS 7 EOL repos (not addressed early enough)

---

## [2.0.0] — 2026-03-13

- Added Rocky Linux support
- Added leapp inhibitor auto-remediation
- Added backup phase

---

## [1.0.0] — 2026-03-13

- Initial release
- Basic CentOS 7 → AlmaLinux 8 automation
