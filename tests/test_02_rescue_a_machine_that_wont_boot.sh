#!/usr/bin/env bash
# sys-02 — Rescue mode and a broken boot.
#
# The invariant, and why it cannot be faked by reading a file: a bad /etc/fstab
# line stops the boot. The proof of a fix is not "the line is gone" — it is that
# the machine, powered off and on, reaches a login prompt. So this test:
#
#   1. boots the target, confirms a clean baseline (no fault, reaches login)
#   2. seeds a real fault (an unresolvable UUID in fstab) and power-cycles
#   3. reads the SERIAL log: the boot must stop at emergency, SSH must be down
#   4. repairs it from a RESCUE system (target disk attached as a 2nd drive) —
#      never with host root, and only after mounting the disk read-write
#   5. boots the SAME repaired overlay and confirms it reaches login again
#   6. confirms the CAUSE is gone (no bad line), not just the symptom
#
# Proven by hand on 2026-08-25 (gemello: 20_Progetti/linuxlab-percorsi.md) before
# being encoded here.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

BAD_UUID="deadbeef-dead-dead-dead-deaddeadbeef"
BAD_LINE="UUID=$BAD_UUID /srv/broken ext4 defaults 0 2"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-02 — rescue a machine that won't boot${RESET}"; echo ""

# --- 1. clean baseline ------------------------------------------------------
log_info "Booting the target (clean baseline)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH from a clean boot" banco_wait_ssh "$SSH" 200
if grep -aqE "$BANCO_LOGIN_RE" "$TLOG"; then log_ok "clean boot reaches login on the serial console"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "clean boot did not complete on the serial"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
refute "baseline fstab has no seeded fault" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"

# --- 2. seed the fault + power-cycle ----------------------------------------
log_info "Seeding a bad fstab line and rebooting the guest..."
$SSH "echo '$BAD_LINE' | sudo tee -a /etc/fstab >/dev/null" >/dev/null 2>&1
assert "the fault is now in fstab" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"
# Mark where the pre-reboot log ends, so we read the NEXT boot's verdict.
before_lines=$(wc -l < "$TLOG")
banco_reboot_guest "$SSH"

# --- 3. the serial oracle: emergency, and SSH down --------------------------
log_info "Reading the serial console for the broken boot..."
# Wait for the emergency markers to appear AFTER the reboot point.
ok_emerg=1
for _ in $(seq 1 50); do
    tail -n +"$((before_lines+1))" "$TLOG" | grep -aqE "$BANCO_EMERGENCY_RE" && { ok_emerg=0; break; }
    sleep 3
done
if [[ "$ok_emerg" -eq 0 ]]; then log_ok "the broken boot stops at emergency (serial)"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "no emergency markers on the serial after the fault"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
refute "SSH is down while in emergency mode" bash -c "$SSH true"
banco_stop_pid "$TPID"

# --- 4. repair from a rescue system -----------------------------------------
log_info "Booting a rescue system and repairing the disk offline..."
repair="sudo mount /dev/vdb1 /mnt && sudo sed -i '/$BAD_UUID/d' /mnt/etc/fstab && echo REMAINING=\$(grep -c $BAD_UUID /mnt/etc/fstab || echo 0) && sudo umount /mnt"
out="$(banco_rescue_run "$BASE_IMAGE" "$TARGET_OVERLAY" "$SSH_KEY" "$repair" 2299 "$CIDATA_ISO")"
assert_contains "rescue mounted the disk and removed the bad line" "$out" "REMAINING=0"

# --- 5. boot the SAME repaired overlay --------------------------------------
log_info "Booting the repaired target (same overlay, not a fresh one)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "the repaired machine answers SSH again" banco_wait_ssh "$SSH" 200
if grep -aqE "$BANCO_LOGIN_RE" "$TLOG"; then log_ok "the repaired boot reaches login on the serial"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "the repaired boot did not complete on the serial"; FAIL_COUNT=$((FAIL_COUNT+1)); fi

# --- 6. the cause is gone, not just the symptom -----------------------------
refute "the CAUSE is gone: no bad line survives in fstab" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-02: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
