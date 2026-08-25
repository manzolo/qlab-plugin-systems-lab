# systems-lab — Linux Systems: boot, kernel, disks & recovery

[![QLab Plugin](https://img.shields.io/badge/QLab-Plugin-blue)](https://github.com/manzolo/qlab)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A [QLab](https://github.com/manzolo/qlab) plugin — the **Linux Systems** track of the
[Linux Lab](https://manzolo.github.io/LinuxLab/) family. Where *Linux Core* teaches you to
administer a machine that is already up, this teaches you how it comes up in the first
place, and how to get it back when it won't.

## The one idea

**The boot IS the test.** A running `sshd` is not proof that a machine boots — the proof is
what the serial console says as PID 1 comes up from cold. So every exercise seeds a *real*
fault, powers the machine off and on, and reads the verdict from the boot itself, never from
a file on a disk that never rebooted. A fix that only silences the symptom does not pass:
the check re-boots the machine and asks whether it reached a login prompt.

This is the same move as the *cyber-lab* sibling ("the attack is the test"), turned onto the
boot path. It needs a real VM: a container shares the host kernel, runs no firmware, has no
bootloader and no initramfs, so it cannot prove a boot at all.

## What runs

One VM, `systems-lab-target`: Ubuntu 22.04 on QEMU/KVM — the **standard** server cloud image
(kernel `-virtual`, full module set), not the minimal one the other plugins use: the minimal's
`linux-kvm` kernel ships **no dm-crypt at all**, so the LUKS chapter would be impossible there
(found live, 2026-08-25). An extra empty data disk sits on `/dev/vdb` for the storage chapters. When a chapter breaks the boot, you recover it from a
**rescue system** — a throwaway VM booted from the base image with the broken disk attached
as a second drive. That rescue path is not a workaround; it *is* chapter sys-02.

## The bench (`lib/banco.sh`)

The measures on 2026-08-25 found that `qlab run` recreates the overlay disk on every run —
which would erase a repair between breaking the machine and re-booting it. So the exercises
drive the target through a small bench that keeps the *same* overlay across a power-cycle:

- **serial oracle** — reads the qlab serial log for the two verdicts a boot can reach
  (`emergency` vs `login`), so a test can assert one and refute the other;
- **power-cycle** — reboots from inside the guest (QEMU stays alive, the overlay survives);
- **offline rescue** — boots a rescue VM with the target disk attached, repairs it there
  (never with host root), and proves ownership by mounting the disk read-write before
  touching it.

## Chapters (planned)

| ID | Chapter | Invariant |
|----|---------|-----------|
| **sys-01** | **How Linux really boots** | **the machine boots with a required kernel parameter (in /proc/cmdline after a real power-cycle), and the boot log shows it** ✅ *green* |
| **sys-02** | **Rescue mode & a broken boot** | **a seeded fault stops the boot; after repair the machine reaches login again, and the *cause* is gone** ✅ *green* |
| **sys-03** | **Kernel, modules, /proc, /sys, sysctl** | **a sysctl value is live, persisted, and still live after a real power-cycle; a module is loaded, seen in lsmod and /sys/module, and unloaded** ✅ *green* |
| **sys-04** | **Partitions on virtual disks** | **a real GPT partition, mounted by UUID in fstab, comes back by itself after a reboot** ✅ *green* |
| **sys-05** | **LUKS & layered storage** | **from the attacker's viewpoint (the rescue with the disks in hand): a chmod-600 file on the clear disk IS readable, the LUKS secret appears NOWHERE in the raw bytes — and the owner, with the passphrase, loses nothing** ✅ *green* |
| **sys-06** | **Persistent networking** | **act 1: an address set with ip(8) EVAPORATES across a power-cycle; act 2: the same address, a route and a DNS server via netplan/systemd-networkd (matched by MAC) come back by themselves — measured separately, live** ✅ *green* |
| **sys-07** | **Diagnostics & performance** | **the machine has ONE of several faults (cpu / memory / full disk): the check demands the right classification from live metrics FIRST, then a measurement-driven cure, then 'sano' again — and the classifier must stay silent on a healthy machine** ✅ *green* |
| **sys-08** | **Capstone: recover a machine that won't start** | **chained faults (a boot-blocker hiding a dead service); the check starts from a POWERED-OFF machine and ends with everything alive on a fresh boot** ✅ *green* |

**All eight chapters are green end-to-end on real VMs** (sys-08 in its reduced form — the
full-blown capstone with more chained faults is the remaining growth).

## Quick start

```bash
qlab install systems-lab
qlab run systems-lab          # provisions + boots the target (~60s first boot)
qlab shell systems-lab-target # log in: labuser / labpass
# ...break something, then:
qlab stop systems-lab
qlab test systems-lab         # heavy: it power-cycles a real VM
```

## Credentials

`labuser` / `labpass` (passwordless sudo).

## Status

**v0.6 — the track is complete: all eight chapters pass end-to-end on real VMs.** Each one
seeds a change and reads the verdict from the living system or from a real power-cycle; the
capstone starts from a machine that is actually powered off. See `STATO.md` for what was
proven and the bugs the live runs found; `BACKLOG.md` for what's next.
