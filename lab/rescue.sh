#!/usr/bin/env bash
# rescue.sh — boot a rescue system with the target's disk attached, for the
# interactive path of chapter sys-02. This is the human version of what the test
# suite does through lib/banco.sh (banco_rescue_run).
#
# It STOPS the target first: two live writers on one qcow2 corrupt it. When you
# power the rescue off, run `qlab run systems-lab` to boot the (repaired) target.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"

# Find the workspace (dir containing .qlab), same logic as the tests.
d="$PLUGIN_DIR"
while [[ "$d" != "/" && ! -d "$d/.qlab" ]]; do d="$(dirname "$d")"; done
[[ -d "$d/.qlab" ]] || { echo "No .qlab workspace found. Run 'qlab run systems-lab' first."; exit 1; }
WS="$d"

BASE="$WS/.qlab/images/ubuntu-22.04-server-cloudimg-amd64.img"
TARGET_DISK="$HERE/systems-lab-target-disk.qcow2"
KEY="$WS/.qlab/ssh/qlab_id_rsa"
PORT="${RESCUE_PORT:-2299}"

[[ -f "$TARGET_DISK" ]] || { echo "Target disk not found: $TARGET_DISK"; exit 1; }

echo "Stopping the target VM (a disk cannot have two live writers)..."
qlab stop systems-lab >/dev/null 2>&1 || true
sleep 2

WORK="$(mktemp -d)"
RESCUE="$WORK/rescue.qcow2"
qemu-img create -f qcow2 -b "$BASE" -F qcow2 "$RESCUE" >/dev/null

# The rescue boots from the plain base image: it needs its OWN cloud-init seed to
# create labuser + install the workspace key, or sshd never comes up. Reuse the
# target's cidata (it only configures the OS user/key).
CIDATA="$HERE/cidata-rescue.iso"
[[ -f "$CIDATA" ]] || CIDATA="$HERE/cidata-target.iso"
CD=()
[[ -f "$CIDATA" ]] && CD=(-cdrom "$CIDATA")

KVM=()
[[ -e /dev/kvm && -w /dev/kvm ]] && KVM=(-enable-kvm -cpu host)

echo "Booting the rescue system (target disk is /dev/vdb there)..."
qemu-system-x86_64 -m 1024 -smp 1 -display none -monitor none -daemonize \
    -pidfile "$WORK/rescue.pid" -serial "file:$WORK/rescue.log" \
    -drive "file=$RESCUE,format=qcow2,if=virtio" \
    -drive "file=$TARGET_DISK,format=qcow2,if=virtio" \
    "${CD[@]}" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22" \
    -device virtio-net-pci,netdev=net0 "${KVM[@]}"

echo "Waiting for the rescue system to answer on port $PORT..."
SSH="ssh -i $KEY -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes labuser@127.0.0.1"
for _ in $(seq 1 45); do $SSH true >/dev/null 2>&1 && break; sleep 4; done

cat <<TIP

  You are about to enter the rescue system. The broken machine's root filesystem
  is on /dev/vdb1 (its data disk is /dev/vdc). To repair, typically:

    sudo mount /dev/vdb1 /mnt
    sudo vim /mnt/etc/fstab        # fix the offending line
    sudo umount /mnt
    sudo poweroff

  Then, back on the host:  qlab run systems-lab

TIP

exec $SSH
