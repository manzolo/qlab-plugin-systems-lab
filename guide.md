# systems-lab — step-by-step guide

> **New here?** This is the *Linux Systems* track. It assumes you can already move
> around a Linux system and edit files — if not, do *Linux Core* first
> (<https://manzolo.github.io/LinuxLab/>).

The rule is simple and it never bends: **the boot is the test.** You will not be asked
"did you edit the file?" — you will be asked "does the machine come back?" A repair that
only hides the symptom fails, because the check powers the machine off and on and reads the
serial console.

## Getting in

```bash
qlab run systems-lab
qlab shell systems-lab-target      # labuser / labpass
```

You get one machine with:

- a real boot path — firmware, GRUB, initramfs, `/etc/fstab`, systemd targets;
- an extra empty data disk on `/dev/vdb` (for the storage chapters);
- passwordless `sudo`.

## sys-02 — rescue mode and a broken boot

The exercise breaks the boot by putting a line in `/etc/fstab` that points at a filesystem
that does not exist. On the next boot systemd cannot satisfy the mount, the dependency
chain fails, and you land in an **emergency shell** — or, with no console, a machine that
simply never answers.

You cannot fix it from inside, because there is no inside to log into. You fix it the way a
sysadmin does: from a **rescue system**.

```bash
# From the host, with the target stopped:
bash lab/rescue.sh
```

That boots a small rescue VM with the broken machine's disk attached as `/dev/vdb`. Inside:

```bash
sudo mount /dev/vdb1 /mnt          # mount the broken root, read-write
sudo vim /mnt/etc/fstab            # remove (or fix) the offending line
sudo umount /mnt
sudo poweroff
```

Back on the host:

```bash
qlab run systems-lab               # boot the repaired machine
```

**What the check looks at:** it re-boots the machine from the repaired disk and confirms it
reaches a login prompt on the serial console, then confirms the *cause* is gone — the bad
line is no longer in `fstab`. Commenting out every check, or masking the mount, does not
pass: the machine has to actually come up, and the fault has to actually be gone.

### Why not just edit the file and trust it?

Because a file says nothing about whether the machine boots. The whole skill here is reading
the boot, understanding why it stopped, and proving the fix by watching it come back. That
is what the serial console is for, and it is what the check reads.
