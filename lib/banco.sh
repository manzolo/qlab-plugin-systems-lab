#!/usr/bin/env bash
# banco.sh — the bench for Linux Systems.
#
# The idea that holds this lab together: the BOOT is the test. A running SSH
# daemon is not proof that a machine boots — the proof is what the serial console
# says as PID 1 comes up from cold. So the exercises seed a real fault, power the
# machine off and on, and read the verdict from the serial log, not from a file
# on a disk that never went through a boot.
#
# Four capabilities, each proven by hand on 2026-08-25 before being written here
# (see the gemello note 20_Progetti/linuxlab-percorsi.md, "Esiti delle misure"):
#
#   1. serial oracle       — banco_serial_has / banco_wait_serial
#   2. power-cycle in test — banco_reboot_guest (reboot from inside; QEMU stays
#                            alive, so the overlay is NOT recreated the way
#                            `qlab run` would)
#   3. offline inspection  — banco_rescue_run (a rescue VM with the target disk
#                            attached as a second drive: no root on the host, and
#                            it IS chapter sys-02)
#   4. proof before touch  — banco_rescue_run repairs a disk only after mounting
#                            it read-write from the rescue system; the caller
#                            asserts the CAUSE is gone, not just the symptom.
#
# These functions run on the HOST, inside the test suite. They read the serial
# log that qlab already writes (-serial file:...) and drive a throwaway rescue
# VM with plain qemu.

# ---- serial oracle --------------------------------------------------------

# Path to the serial log qlab writes for a VM.
banco_serial_log() {
    local vm="$1"
    echo "${WORKSPACE_DIR:?}/.qlab/logs/${vm}.log"
}

# True if the serial log currently contains the extended-regex pattern.
# Reads bytes literally: boot logs carry ANSI colour, so match on the words.
banco_serial_has() {
    local vm="$1" pattern="$2"
    grep -aqE "$pattern" "$(banco_serial_log "$vm")" 2>/dev/null
}

# Wait up to <timeout> seconds for EITHER pattern to appear. Returns 0 as soon
# as it does, 1 on timeout. Silence is never a pass: the caller must say which
# pattern it wanted and check afterwards.
banco_wait_serial() {
    local vm="$1" pattern="$2" timeout="${3:-120}"
    local waited=0
    while [[ "$waited" -lt "$timeout" ]]; do
        banco_serial_has "$vm" "$pattern" && return 0
        sleep 3; waited=$((waited + 3))
    done
    return 1
}

# The two verdicts a boot can reach. Distinct patterns so a test can assert one
# and refute the other — a machine that reached "login" did NOT stop at emergency.
BANCO_EMERGENCY_RE='Emergency Shell|emergency mode|Dependency failed|Failed to mount'
BANCO_LOGIN_RE='login:|Reached target .*Multi-User|systemd.*Startup finished'

banco_boot_broke() { banco_wait_serial "$1" "$BANCO_EMERGENCY_RE" "${2:-150}"; }
banco_boot_clean() { banco_wait_serial "$1" "$BANCO_LOGIN_RE"     "${2:-150}"; }

# ---- power-cycle ----------------------------------------------------------

# Reboot the guest from inside, over SSH. QEMU stays alive, so the overlay disk
# survives — unlike `qlab run`, which does `rm -f overlay` and rebuilds from the
# base image (proven on 2026-08-25; it is why a fault must be re-read from the
# serial log after THIS, not after a fresh run). The serial log keeps appending.
banco_reboot_guest() {
    local ssh_cmd="$1"
    # `reboot` may drop the connection before returning; that is expected.
    $ssh_cmd "sudo systemctl reboot" >/dev/null 2>&1 || true
}

# Reboot and wait until we are provably on a NEW boot, not the old session that
# lingers for a few seconds while services stop. The boot_id changes every boot,
# so we capture it, reboot, and wait for SSH to answer with a DIFFERENT one.
# Without this, a check that reads /proc/cmdline can race onto the pre-reboot
# kernel and read stale state (learned on sys-01, 2026-08-25). Returns 0 once the
# new boot is up, 1 on timeout.
banco_reboot_wait_newboot() {
    local ssh_cmd="$1" timeout="${2:-220}"
    local before after waited=0
    before="$($ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n ')"
    $ssh_cmd "sudo systemctl reboot" >/dev/null 2>&1 || true
    sleep 8
    while [[ "$waited" -lt "$timeout" ]]; do
        after="$($ssh_cmd 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n ')"
        if [[ -n "$after" && "$after" != "$before" ]]; then return 0; fi
        sleep 4; waited=$((waited + 4))
    done
    return 1
}

# ---- booting the target under the bench's control -------------------------
#
# WHY the bench boots the target itself instead of `qlab run`: qlab's run does
# `rm -f overlay` and rebuilds from the base image every time (proven 2026-08-25),
# which would erase a repair between the break and the re-boot. The bench needs
# the SAME overlay to survive a power-cycle, so it drives qemu directly. This is
# the "start that does not recreate the disk" the measures said Systems needs.
#
# banco_boot_target <overlay> <data_disk> <log> <pidfile> [ssh_port] [extra qemu args...]
# Boots the target standalone, SSH forwarded, serial to <log>. Non-blocking.
# Anything after the port is passed to qemu verbatim (e.g. a second NIC on an
# isolated mcast LAN for the networking chapter).
banco_boot_target() {
    local overlay="$1" data="$2" log="$3" pidfile="$4" port="${5:-2288}"
    shift 5 2>/dev/null || shift $#
    local extra=("$@")
    local kvm=()
    [[ -e /dev/kvm && -w /dev/kvm ]] && kvm=(-enable-kvm -cpu host)
    local data_arg=()
    [[ -n "$data" && -f "$data" ]] && data_arg=(-drive "file=$data,format=qcow2,if=virtio")
    qemu-system-x86_64 -m "${BANCO_MEMORY:-1024}" -smp 1 -display none -monitor none \
        -daemonize -pidfile "$pidfile" -serial "file:$log" \
        -drive "file=$overlay,format=qcow2,if=virtio" \
        "${data_arg[@]}" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:22" \
        -device virtio-net-pci,netdev=net0 \
        "${extra[@]+"${extra[@]}"}" "${kvm[@]}"
}

# Stop a bench-booted VM by pidfile (best effort, then force).
banco_stop_pid() {
    local pidfile="$1"
    [[ -f "$pidfile" ]] || return 0
    local pid; pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null || true
    local g=0
    while [[ "$g" -lt 15 ]] && kill -0 "$pid" 2>/dev/null; do sleep 1; g=$((g + 1)); done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
}

# SSH command string for a bench-booted target on the given port.
banco_ssh() {
    local key="$1" port="${2:-2288}"
    echo "ssh -i $key -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes labuser@127.0.0.1"
}

# Wait until a bench-booted target answers SSH (returns 0) or times out (1).
banco_wait_ssh() {
    local ssh_cmd="$1" timeout="${2:-180}" waited=0
    while [[ "$waited" -lt "$timeout" ]]; do
        $ssh_cmd true >/dev/null 2>&1 && return 0
        sleep 4; waited=$((waited + 4))
    done
    return 1
}

# Power the guest OFF (not reboot) and wait until QEMU itself has exited: on
# guest shutdown a daemonized QEMU quits, which is exactly the "VM spenta" state
# the capstone check must start from. Returns 0 when the process is gone.
banco_poweroff_wait() {
    local ssh_cmd="$1" pidfile="$2" timeout="${3:-90}"
    local pid waited=0
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    $ssh_cmd "sudo poweroff" >/dev/null 2>&1 || true
    while [[ "$waited" -lt "$timeout" ]]; do
        [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && { rm -f "$pidfile"; return 0; }
        sleep 3; waited=$((waited + 3))
    done
    # Last resort: it did not power off by itself.
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$pidfile"
    return 1
}

# ---- QMP: talk to a running QEMU ------------------------------------------
#
# Sends one HMP command through the QMP unix socket. Used to hot-plug the
# target's disk into the rescue AFTER it has booted — because rescue and target
# derive from the same base image and share PARTUUIDs, and if both disks are
# present at boot the kernel picks its root by SCAN ORDER, not by merit: on
# 2026-08-25 the rescue mounted the TARGET's poisoned root as its own and
# landed in emergency mode. A rescue must boot alone; the patient arrives later.
_banco_qmp_hmp() {
    local sock="$1" cmdline="$2"
    python3 - "$sock" "$cmdline" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw')
json.loads(f.readline())  # greeting
def ex(o):
    f.write(json.dumps(o) + '\n'); f.flush()
    while True:
        r = json.loads(f.readline())
        if 'return' in r or 'error' in r:
            return r
ex({"execute": "qmp_capabilities"})
r = ex({"execute": "human-monitor-command", "arguments": {"command-line": sys.argv[2]}})
out = r.get('return', r)
if isinstance(out, str) and out.strip():
    print(out.strip())
if 'error' in r:
    sys.exit(1)
PY
}

# ---- offline rescue -------------------------------------------------------

# Boot a throwaway rescue VM from the base image, with the target's disk attached
# as a SECOND drive, run a repair command against it, then power the rescue off.
# This is capability #3 and #4 at once, and it is literally what a person does in
# chapter sys-02.
#
#   banco_rescue_run <base_image> <target_disk> <ssh_key> <repair_cmd> [port] [cidata_iso] [extra_disk]
#
# [extra_disk] optionally attaches a further disk (e.g. the target's data disk)
# as /dev/vdc in the rescue — needed when the inspection concerns data that does
# not live on the root disk (sys-05: is the LUKS volume really unreadable?).
#
# The <repair_cmd> runs inside the rescue VM as a shell string. The target disk
# appears there as /dev/vdb (the rescue root is /dev/vda). A repair typically
# mounts /dev/vdb1, edits, and unmounts — proving ownership by reading the disk,
# never by trusting a name.
#
# <cidata_iso> is REQUIRED for SSH: the rescue boots from the plain base cloud
# image, which has NO user and NO key of its own — so it needs a cloud-init seed
# to create labuser and install the workspace key, exactly like the target. Skip
# it and the rescue boots to a login prompt you cannot log into (learned the hard
# way, 2026-08-25: "Failed to start OpenBSD Secure Shell server", no user).
#
# IMPORTANT: the target VM must be STOPPED before calling this. Two live writers
# on one qcow2 corrupt it. The caller (a test) is responsible for the order.
banco_rescue_run() {
    local base_image="$1" target_disk="$2" ssh_key="$3" repair_cmd="$4"
    local port="${5:-2299}" cidata="${6:-}" extra_disk="${7:-}"
    local work; work="$(mktemp -d)"
    local rescue_disk="$work/rescue.qcow2" rescue_log="$work/rescue.log"
    local rescue_pid="$work/rescue.pid"

    qemu-img create -f qcow2 -b "$base_image" -F qcow2 "$rescue_disk" >/dev/null 2>&1 || return 1

    local kvm=()
    [[ -e /dev/kvm && -w /dev/kvm ]] && kvm=(-enable-kvm -cpu host)
    local cd_arg=()
    [[ -n "$cidata" && -f "$cidata" ]] && cd_arg=(-cdrom "$cidata")

    # The rescue boots ALONE (see _banco_qmp_hmp for why); the target disk and
    # the optional extra disk are hot-plugged over QMP once it is up.
    qemu-system-x86_64 -m 1024 -smp 1 -display none -monitor none -daemonize \
        -pidfile "$rescue_pid" -serial "file:$rescue_log" \
        -qmp "unix:$work/qmp.sock,server,nowait" \
        -drive "file=$rescue_disk,format=qcow2,if=virtio" \
        "${cd_arg[@]}" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:22" \
        -device virtio-net-pci,netdev=net0 \
        "${kvm[@]}" || { rm -rf "$work"; return 1; }

    local ssh_opts="-i $ssh_key -p $port -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes"

    # Wait for the rescue system to answer. 300s, not less: on the standard
    # image the rescue's first boot installs packages over SLIRP and runs
    # update-grub, and 180s was not enough (found live, 2026-08-25 — the
    # timeout aborted sys-02 mid-rescue and poisoned the suite).
    local up=1 waited=0
    while [[ "$waited" -lt 300 ]]; do
        # shellcheck disable=SC2086
        if ssh $ssh_opts labuser@127.0.0.1 true >/dev/null 2>&1; then up=0; break; fi
        sleep 4; waited=$((waited + 4))
    done
    if [[ "$up" -ne 0 ]]; then
        # NEVER destroy the evidence: the rescue's serial log says why it did
        # not come up (a failure erased silently here cost a whole debugging
        # round on 2026-08-25). stderr, so command substitution doesn't eat it.
        {
            echo "banco_rescue_run: rescue did not answer SSH; last serial lines:"
            tail -c 2000 "$rescue_log" 2>/dev/null | strings | tail -15
        } >&2
        banco_stop_pid "$rescue_pid"
        rm -rf "$work"; return 1
    fi

    # Hot-plug the patient(s): the target disk becomes /dev/vdb, the optional
    # extra disk /dev/vdc. Done only NOW, with the rescue's root already
    # mounted, so the PARTUUID twins can no longer confuse the kernel.
    _banco_qmp_hmp "$work/qmp.sock" "drive_add 0 if=none,file=$target_disk,format=qcow2,id=banco_tgt" >&2 || true
    _banco_qmp_hmp "$work/qmp.sock" "device_add virtio-blk-pci,drive=banco_tgt,id=banco_tgt_dev" >&2 || true
    local want_dev="test -b /dev/vdb"
    if [[ -n "$extra_disk" && -f "$extra_disk" ]]; then
        _banco_qmp_hmp "$work/qmp.sock" "drive_add 0 if=none,file=$extra_disk,format=qcow2,id=banco_extra" >&2 || true
        _banco_qmp_hmp "$work/qmp.sock" "device_add virtio-blk-pci,drive=banco_extra,id=banco_extra_dev" >&2 || true
        want_dev="test -b /dev/vdb && test -b /dev/vdc"
    fi
    local seen=1 w2=0
    while [[ "$w2" -lt 30 ]]; do
        # shellcheck disable=SC2086
        if ssh $ssh_opts labuser@127.0.0.1 "$want_dev" >/dev/null 2>&1; then seen=0; break; fi
        sleep 2; w2=$((w2 + 2))
    done
    if [[ "$seen" -ne 0 ]]; then
        echo "banco_rescue_run: hot-plugged disk(s) never appeared in the rescue" >&2
        banco_stop_pid "$rescue_pid"; rm -rf "$work"; return 1
    fi

    # Run the repair; capture its output for the caller's log.
    local out rc
    # shellcheck disable=SC2086
    out=$(ssh $ssh_opts labuser@127.0.0.1 "$repair_cmd" 2>&1); rc=$?
    echo "$out"

    # Shut the rescue down cleanly (best effort), then make sure it is gone.
    # shellcheck disable=SC2086
    ssh $ssh_opts labuser@127.0.0.1 "sudo poweroff" >/dev/null 2>&1 || true
    local g=0
    while [[ "$g" -lt 20 ]]; do
        [[ -f "$rescue_pid" ]] && kill -0 "$(cat "$rescue_pid")" 2>/dev/null || break
        sleep 1; g=$((g + 1))
    done
    # Whatever happened above, make SURE the process is gone before returning:
    # a dying qemu still holds the write lock on the target disk, and the next
    # boot fails with 'Failed to get "write" lock' (bitten on 2026-08-25).
    banco_stop_pid "$rescue_pid"
    rm -rf "$work"
    return "$rc"
}
