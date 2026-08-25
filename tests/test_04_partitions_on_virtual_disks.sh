#!/usr/bin/env bash
# sys-04 — Partitions on virtual disks.
#
# The invariant, and why a reboot is the only honest check: a mount you type by
# hand exists until the next boot; a mount that is really configured comes back
# by itself. And it must come back by IDENTITY (UUID), not by device name — the
# PARTUUID-collision trap (2026-08-25) is exactly why /dev/vdb1 is the wrong
# thing to trust. So this test, on the empty data disk /dev/vdb:
#
#   1. makes a real GPT partition, a filesystem, notes its UUID
#   2. mounts it by UUID via /etc/fstab (with nofail, so a bad line cannot brick
#      the boot — the good habit)
#   3. power-cycles the machine
#   4. confirms the mount came back BY ITSELF, and that it is the UUID mount
#   5. tears down (wipes the partition table, cleans fstab) so the overlay and
#      the data disk return to baseline for other tests
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

MP="/srv/data"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-04 — partitions on virtual disks${RESET}"; echo ""

log_info "Booting the target..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200
assert "the empty data disk /dev/vdb is present" bash -c "$SSH 'test -b /dev/vdb'"
refute "nothing is mounted at $MP yet" bash -c "$SSH 'findmnt -rno TARGET $MP'"

# --- 1. real GPT partition + filesystem -------------------------------------
log_info "Creating a GPT partition and an ext4 filesystem on /dev/vdb..."
$SSH "sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo sgdisk -n 1:0:0 -t 1:8300 /dev/vdb >/dev/null 2>&1; sudo partprobe /dev/vdb 2>/dev/null; sleep 1; sudo mkfs.ext4 -q -F /dev/vdb1 >/dev/null 2>&1" >/dev/null 2>&1 || true
pt=$($SSH "sudo blkid -o value -s PTTYPE /dev/vdb 2>/dev/null" || true)
assert_contains "the disk carries a real GPT partition table" "$pt" "gpt"
UUID=$($SSH "sudo blkid -o value -s UUID /dev/vdb1 2>/dev/null" | tr -d '\r\n ')
assert "the new filesystem has a UUID" bash -c "[[ -n '$UUID' ]]"

# --- 2. mount by UUID via fstab (nofail) ------------------------------------
log_info "Mounting by UUID via /etc/fstab (nofail), then mount -a..."
$SSH "sudo mkdir -p $MP && echo 'UUID=$UUID $MP ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null && sudo mount -a" >/dev/null 2>&1 || true
assert "the fstab line uses the UUID, not /dev/vdb1" bash -c "$SSH 'grep -q \"UUID=$UUID\" /etc/fstab'"
assert "it is mounted now" bash -c "$SSH 'findmnt -rno TARGET $MP'"

# --- 3. power-cycle ---------------------------------------------------------
log_info "Rebooting: a real mount comes back by itself..."
assert "target came back on a NEW boot (boot_id changed)" banco_reboot_wait_newboot "$SSH" 220

# --- 4. the honest proof: the mount returned BY ITSELF, by UUID -------------
assert "the mount came back after reboot, untouched" bash -c "$SSH 'findmnt -rno TARGET $MP'"
src=$($SSH "findmnt -rno SOURCE $MP 2>/dev/null" | tr -d '\r\n ')
back_uuid=$($SSH "sudo blkid -o value -s UUID \"$src\" 2>/dev/null" | tr -d '\r\n ')
assert "the mounted device is the one with our UUID" bash -c "[[ '$back_uuid' == '$UUID' ]]"

# --- 5. teardown to baseline ------------------------------------------------
log_info "Tearing down (unmount, clean fstab, wipe the partition table)..."
$SSH "sudo umount $MP 2>/dev/null; sudo sed -i '\|$MP|d' /etc/fstab; sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo wipefs -a /dev/vdb >/dev/null 2>&1; sudo rmdir $MP 2>/dev/null" >/dev/null 2>&1 || true
refute "fstab no longer references $MP" bash -c "$SSH 'grep -q \"$MP\" /etc/fstab'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-04: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
