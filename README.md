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

One VM, `systems-lab-target`: Ubuntu on QEMU/KVM, with an extra empty data disk on
`/dev/vdb` for the storage chapters. When a chapter breaks the boot, you recover it from a
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
| sys-01 | How Linux really boots | the machine boots with a required kernel parameter, and you show where it was read |
| **sys-02** | **Rescue mode & a broken boot** | **a seeded fault stops the boot; after repair the machine reaches login again, and the *cause* is gone** ✅ *encoded* |
| sys-03 | Kernel, modules, /proc, /sys, sysctl | a sysctl value is correct at runtime, persistent on disk, and still there after a reboot |
| sys-04 | Partitions on virtual disks | a real GPT partition, mounted by UUID in fstab, survives a reboot |
| sys-05 | LUKS & layered storage | with the volume closed, the data is unreadable (checked from the rescue system) |
| sys-06 | Persistent networking | IP/route/DNS come back after a reboot, measured separately |
| sys-07 | Diagnostics & performance | classify the bottleneck before fixing it |
| sys-08 | Capstone: recover a machine that won't start | chained faults; the check boots the VM from cold |

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

**v0.1 — sys-02 encoded and driven by the bench.** The recovery mechanism was proven by
hand before being written here (see `STATO.md`). More chapters follow; see `BACKLOG.md`.
