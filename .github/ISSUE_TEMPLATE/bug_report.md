---
name: Bug Report
about: Report a problem with the migration script
title: "[BUG] "
labels: bug
assignees: ''
---

## Bug Description

A clear description of what went wrong.

## Environment

| Field | Value |
|---|---|
| Script version | (from header or `grep SCRIPT_VERSION centos7_to_el8_migrate.sh`) |
| CentOS version | (`cat /etc/centos-release`) |
| Target distro | AlmaLinux 8 / Rocky Linux 8 |
| Virtualisation | (`systemd-detect-virt`) |
| Storage | LVM / bare disk / RAID |
| Architecture | x86_64 |

## Command Used

```bash
sudo ./centos7_to_el8_migrate.sh --target XXXX ...
```

## Expected Behaviour

What should have happened.

## Actual Behaviour

What actually happened.

## Log Excerpt

```
Paste relevant lines from /var/log/el8-migration/*.log
(Remove any sensitive information — IPs, hostnames, etc.)
```

## Additional Context

Any other relevant information (custom kernel modules, unusual repos, etc.)
