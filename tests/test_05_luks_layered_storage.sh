#!/usr/bin/env bash
# sys-05 — LUKS and layered storage.
#
# The invariant, and why the RESCUE VM is the honest place to check it: the
# rescue system is the attacker with the disk in their hands. File permissions
# mean nothing there — it mounts your root disk and reads everything. What
# survives that viewpoint is only what is encrypted. So this test builds both
# sides of the lesson in one scene:
#
#   1. a secret written INSIDE a LUKS volume on the data disk
#   2. a file written IN CLEAR on the root disk, protected only by permissions
#   3. volume closed, machine POWERED OFF
#   4. the rescue (= the attacker) gets BOTH disks:
#        - the clear file on the root disk is readable        (permissions lost)
#        - the LUKS partition says crypto_LUKS and the secret
#          does NOT appear anywhere in the raw bytes          (encryption holds)
#   5. the owner's side: booted again WITH the passphrase, the volume opens,
#      mounts, and the secret is intact — closing lost nothing
#   6. teardown to baseline
#
# No real passwords: passphrase and secrets are run-varying lab tokens.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

NOW=$(date +%s)
PASS="lab-pass-$NOW"
SEGRETO="segreto${NOW}cifrato"
CHIARO="inchiaro${NOW}visibile"
MP="/srv/segreto"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-05 — LUKS and layered storage${RESET}"; echo ""

# --- 1+2. build both sides of the lesson --------------------------------------
log_info "Booting the target..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200

log_info "Creating the LUKS volume on /dev/vdb1 and writing the secret inside..."
$SSH "sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo sgdisk -n 1:0:0 /dev/vdb >/dev/null 2>&1; sudo partprobe /dev/vdb 2>/dev/null; sleep 1" >/dev/null 2>&1 || true
$SSH "echo -n '$PASS' | sudo cryptsetup luksFormat --batch-mode /dev/vdb1 -" >/dev/null 2>&1 || true
lt=$($SSH "sudo blkid -o value -s TYPE /dev/vdb1 2>/dev/null" || true)
assert_contains "the partition is now crypto_LUKS" "$lt" "crypto_LUKS"
# NOTE the syntax: `open` takes the key via --key-file, not as a trailing `-`
# positional (that is luksFormat's signature — mixing them up means the volume
# silently never opens; found live, 2026-08-25). Stderr is captured so a
# failure names itself instead of leaving a bare red.
open_err=$($SSH "echo -n '$PASS' | sudo cryptsetup open --key-file - /dev/vdb1 labcrypt 2>&1" || true)
[[ -n "$open_err" ]] && log_info "cryptsetup open says: $open_err"
assert "the mapping exists in /dev/mapper (the layer a student must see)" \
    bash -c "$SSH 'test -b /dev/mapper/labcrypt'"
$SSH "sudo mkfs.ext4 -q /dev/mapper/labcrypt && sudo mkdir -p $MP && sudo mount /dev/mapper/labcrypt $MP && echo '$SEGRETO' | sudo tee $MP/segreto.txt >/dev/null" >/dev/null 2>&1 || true
assert "the secret is readable through the OPEN volume" \
    bash -c "$SSH 'sudo grep -q $SEGRETO $MP/segreto.txt'"

log_info "Writing the contrast: a clear file on the root disk, chmod 600..."
$SSH "echo '$CHIARO' | sudo tee /root/in-chiaro.txt >/dev/null && sudo chmod 600 /root/in-chiaro.txt" >/dev/null 2>&1 || true
assert "the clear file exists, protected only by permissions" \
    bash -c "$SSH 'sudo grep -q $CHIARO /root/in-chiaro.txt'"

# --- 3. close the volume, power OFF --------------------------------------------
log_info "Closing the volume and powering off (the attacker gets the disks)..."
$SSH "sudo umount $MP && sudo cryptsetup close labcrypt" >/dev/null 2>&1 || true
refute "the mapping is gone after close" bash -c "$SSH 'test -b /dev/mapper/labcrypt'"
assert "the machine powered off (COLD)" banco_poweroff_wait "$SSH" "$TPID" 90

# --- 4. the attacker's viewpoint: the rescue with BOTH disks --------------------
log_info "Rescue = attacker with the disks in hand (root on /dev/vdb, data on /dev/vdc)..."
# The raw-byte probe must first prove it CAN find plaintext (the clear token on
# the unencrypted root disk): a zero from a blind probe reads the same as a zero
# from real encryption — "lo zero ha due letture", and they separate only by
# testing the probe. Only then does SEGRETO_NEI_BYTE=0 mean something.
insp="sudo mount /dev/vdb1 /mnt 2>/dev/null; echo CHIARO_LETTO=\$(sudo grep -c $CHIARO /mnt/root/in-chiaro.txt 2>/dev/null || echo 0); sudo umount /mnt 2>/dev/null; echo CHIARO_NEI_BYTE=\$(sudo grep -a -c -m1 $CHIARO /dev/vdb1 2>/dev/null || echo 0); echo TIPO=\$(sudo blkid -o value -s TYPE /dev/vdc1 2>/dev/null); echo SEGRETO_NEI_BYTE=\$(sudo grep -a -c -m1 $SEGRETO /dev/vdc1 2>/dev/null || echo 0)"
out="$(banco_rescue_run "$BASE_IMAGE" "$TARGET_OVERLAY" "$SSH_KEY" "$insp" 2299 "$RESCUE_CIDATA" "$TARGET_DATA" || true)"
assert_contains "permissions are NOT a defense: the attacker reads the clear file (chmod 600 and all)" "$out" "CHIARO_LETTO=1"
assert_contains "the probe is not blind: plaintext IS found in the raw bytes of the clear disk" "$out" "CHIARO_NEI_BYTE=1"
assert_contains "the attacker sees the LUKS layer for what it is" "$out" "TIPO=crypto_LUKS"
assert_contains "encryption IS a defense: the secret appears NOWHERE in the raw bytes" "$out" "SEGRETO_NEI_BYTE=0"

# --- 5. the owner's side: with the passphrase, nothing was lost ------------------
log_info "Booting the target again: the owner reopens with the passphrase..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target is back up" banco_wait_ssh "$SSH" 200
reopen_err=$($SSH "echo -n '$PASS' | sudo cryptsetup open --key-file - /dev/vdb1 labcrypt 2>&1 && sudo mount /dev/mapper/labcrypt $MP 2>&1" || true)
[[ -n "$reopen_err" ]] && log_info "reopen says: $reopen_err"
assert "with the passphrase the secret is intact after close + power-cycle" \
    bash -c "$SSH 'sudo grep -q $SEGRETO $MP/segreto.txt'"

# --- 6. teardown to baseline ------------------------------------------------------
log_info "Tearing down (close, wipe the data disk, remove the clear file)..."
$SSH "sudo umount $MP 2>/dev/null; sudo cryptsetup close labcrypt 2>/dev/null; sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo wipefs -a /dev/vdb >/dev/null 2>&1; sudo rm -f /root/in-chiaro.txt; sudo rmdir $MP 2>/dev/null" >/dev/null 2>&1 || true
refute "the clear file is gone" bash -c "$SSH 'test -f /root/in-chiaro.txt'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-05: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
