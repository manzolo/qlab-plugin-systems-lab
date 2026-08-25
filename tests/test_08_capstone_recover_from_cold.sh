#!/usr/bin/env bash
# sys-08 (reduced capstone) — Recover a machine that won't start.
#
# Chained faults, and a check that starts from a POWERED-OFF machine — because
# "the reboot cannot be simulated by reading files": only a cold boot proves the
# machine actually comes back. Two faults, deliberately layered:
#
#   A. a bad /etc/fstab line (no nofail)  -> the boot stops at emergency
#   B. a disabled service (lab.service)   -> invisible until A is fixed
#
# The point of the chain: fixing the boot is not the end. A recovered machine
# must also RUN what it is for — and fault B only shows once you are back in.
# The final proof is one more power-cycle with everything alive on a FRESH boot:
# the service writes its heartbeat to /run (tmpfs), so the heartbeat cannot
# survive a reboot — its presence proves the service ran on THIS boot.
#
# Flow (all pieces individually green in sys-01/02/04):
#   1. build the world: lab.service enabled, heartbeat alive
#   2. seed A + B, then POWER OFF (QEMU exits: the machine is cold)
#   3. cold boot -> serial says emergency, SSH down     (A is real)
#   4. rescue VM repairs fstab offline                  (fix A)
#   5. cold boot -> login, but the service is dead      (B emerges)
#   6. unmask + enable                                  (fix B)
#   7. final power-cycle -> login AND heartbeat alive on a fresh boot
#   8. teardown to baseline
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

BAD_UUID="dead0008-dead-dead-dead-deaddead0008"
BAD_LINE="UUID=$BAD_UUID /srv/capstone ext4 defaults 0 2"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-08 — capstone: recover a machine that won't start (from cold)${RESET}"; echo ""

# --- 1. build the world ------------------------------------------------------
log_info "Booting the target and installing the world (lab.service)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200
$SSH "sudo tee /etc/systemd/system/lab.service >/dev/null" <<'UNIT'
[Unit]
Description=Lab heartbeat (proves the machine RUNS, not just boots)

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo alive > /run/lab-heartbeat'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
$SSH "sudo systemctl daemon-reload && sudo systemctl enable --now lab.service" >/dev/null 2>&1
assert "the world is alive: lab.service active, heartbeat written" \
    bash -c "$SSH 'systemctl is-active lab.service >/dev/null && test -f /run/lab-heartbeat'"

# --- 2. seed the chained faults, then power OFF ------------------------------
# Each fault is seeded on its own line with `|| true`, and then ASSERTED: if a
# seed silently fails, the assert says which one — never a silent abort (the
# first run of this test died exactly like that, on a non-zero rc swallowed by
# set -e, 2026-08-25).
log_info "Seeding fault A (bad fstab) + fault B (disabled service), powering off..."
$SSH "echo '$BAD_LINE' | sudo tee -a /etc/fstab >/dev/null" >/dev/null 2>&1 || true
assert "fault A landed: the bad line is in fstab" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"
# Fault B is `disable`, not `mask`: a unit whose file lives in
# /etc/systemd/system cannot be masked — mask must create the /dev/null symlink
# at that very path, which is occupied by the real unit file, so systemctl
# refuses (this rc!=0 is what silently killed the first run, 2026-08-25).
$SSH "sudo systemctl disable --now lab.service" >/dev/null 2>&1 || true
assert "fault B landed: lab.service is disabled" \
    bash -c "$SSH 'systemctl is-enabled lab.service 2>&1 | grep -q disabled'"
assert "the machine powered off by itself (QEMU exited: it is COLD)" \
    banco_poweroff_wait "$SSH" "$TPID" 90

# --- 3. cold boot: fault A is real -------------------------------------------
log_info "Cold boot #1: the broken machine..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
ok_emerg=1
for _ in $(seq 1 50); do
    grep -aqE "$BANCO_EMERGENCY_RE" "$TLOG" && { ok_emerg=0; break; }
    sleep 3
done
if [[ "$ok_emerg" -eq 0 ]]; then log_ok "cold boot stops at emergency (serial)"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "no emergency markers on the cold boot"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
refute "SSH is down on the broken machine" bash -c "$SSH true"
banco_stop_pid "$TPID"

# --- 4. rescue: fix the boot (fault A) ----------------------------------------
log_info "Rescue VM repairs fstab offline..."
repair="sudo mount /dev/vdb1 /mnt && sudo sed -i '/$BAD_UUID/d' /mnt/etc/fstab && echo REMAINING=\$(grep -c $BAD_UUID /mnt/etc/fstab || echo 0) && sudo umount /mnt"
out="$(banco_rescue_run "$BASE_IMAGE" "$TARGET_OVERLAY" "$SSH_KEY" "$repair" 2299 "$CIDATA_ISO")"
assert_contains "rescue removed the bad fstab line" "$out" "REMAINING=0"

# --- 5. cold boot #2: the boot is back, but the machine is not done ----------
log_info "Cold boot #2: fault B emerges..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "the repaired machine reaches SSH again" banco_wait_ssh "$SSH" 200
refute "but the service is still dead (fault B was hiding behind A)" \
    bash -c "$SSH 'systemctl is-active lab.service >/dev/null'"
refute "and no heartbeat was written this boot" bash -c "$SSH 'test -f /run/lab-heartbeat'"

# --- 6. fix fault B ------------------------------------------------------------
log_info "Re-enabling lab.service..."
$SSH "sudo systemctl enable --now lab.service" >/dev/null 2>&1 || true
assert "the service is back" bash -c "$SSH 'systemctl is-active lab.service >/dev/null'"

# --- 7. the final proof: one more power-cycle, everything alive fresh ---------
log_info "Final power-cycle: everything must survive a fresh boot..."
assert "machine came back on a NEW boot" banco_reboot_wait_newboot "$SSH" 220
assert "the service ran on THIS boot (heartbeat in /run, a tmpfs)" \
    bash -c "$SSH 'systemctl is-active lab.service >/dev/null && test -f /run/lab-heartbeat'"
refute "and the bad fstab line never came back" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"

# --- 8. teardown to baseline ---------------------------------------------------
log_info "Tearing down (remove lab.service, leave the overlay at baseline)..."
$SSH "sudo systemctl disable --now lab.service >/dev/null 2>&1; sudo rm -f /etc/systemd/system/lab.service; sudo systemctl daemon-reload" >/dev/null 2>&1 || true
refute "lab.service is gone" bash -c "$SSH 'test -f /etc/systemd/system/lab.service'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-08: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
