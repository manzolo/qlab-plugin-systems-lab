#!/usr/bin/env bash
# sys-03 — Kernel, modules, /proc, /sys and sysctl.
#
# The invariant, and why the reboot is half the lesson: `sysctl -w` changes the
# LIVE kernel and evaporates at shutdown; a file in /etc/sysctl.d survives but
# does nothing until something reads it. Only both together — and a real
# power-cycle — prove a persistent kernel setting. So this test:
#
#   1. picks a run-varying value for kernel.pid_max (not hardcodable)
#   2. baseline: the live kernel does NOT have it
#   3. sets it at runtime AND persists it in /etc/sysctl.d/99-lab.conf
#   4. shows the equivalence a student must see: sysctl IS /proc/sys
#   5. power-cycles: the LIVE kernel still has the value on the new boot
#   6. module roundtrip: find a loadable module on this kernel, modprobe it,
#      see it in lsmod and /sys/module, read modinfo, unload it.
#      If this kernel ships no loadable modules, the test says so LOUDLY —
#      a silent skip would be a green that covers less than it claims.
#   7. teardown to baseline
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

VAL=$((45000 + $(date +%s) % 9999))
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-03 — kernel, /proc, /sys and sysctl${RESET}"; echo ""

# --- 1+2. boot, baseline ------------------------------------------------------
log_info "Booting the target (target value: kernel.pid_max=$VAL)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200
refute "baseline: the live kernel does NOT have the value yet" \
    bash -c "$SSH 'test \"\$(sysctl -n kernel.pid_max)\" = $VAL'"

# --- 3. runtime + persistent --------------------------------------------------
log_info "Setting it live (sysctl -w) and persisting it (/etc/sysctl.d)..."
$SSH "sudo sysctl -w kernel.pid_max=$VAL >/dev/null" >/dev/null 2>&1 || true
assert "the LIVE kernel has the value" \
    bash -c "$SSH 'test \"\$(sysctl -n kernel.pid_max)\" = $VAL'"
$SSH "echo 'kernel.pid_max = $VAL' | sudo tee /etc/sysctl.d/99-lab.conf >/dev/null" >/dev/null 2>&1 || true
assert "the persistent file has the value" \
    bash -c "$SSH 'grep -q \"kernel.pid_max = $VAL\" /etc/sysctl.d/99-lab.conf'"

# --- 4. sysctl IS /proc/sys ----------------------------------------------------
assert "sysctl and /proc/sys are the same thing (kernel.pid_max = /proc/sys/kernel/pid_max)" \
    bash -c "$SSH 'test \"\$(cat /proc/sys/kernel/pid_max)\" = \"\$(sysctl -n kernel.pid_max)\"'"

# --- 5. the honest proof: still there after a real power-cycle -----------------
log_info "Power-cycling: a persistent setting must come back by itself..."
assert "target came back on a NEW boot (boot_id changed)" banco_reboot_wait_newboot "$SSH" 220
assert "the LIVE kernel still has the value on the fresh boot" \
    bash -c "$SSH 'test \"\$(sysctl -n kernel.pid_max)\" = $VAL'"

# --- 6. module roundtrip --------------------------------------------------------
log_info "Module roundtrip: find a loadable module, load it, see it, unload it..."
MOD=$($SSH 'for f in $(find /lib/modules/$(uname -r) -name "*.ko*" 2>/dev/null); do m=$(basename "$f" | sed "s/\.ko.*//"); lsmod | grep -q "^${m} " || { echo "$m"; break; }; done' 2>/dev/null | tr -d '\r\n ')
if [[ -n "$MOD" ]]; then
    log_ok "found a loadable, not-yet-loaded module: $MOD"; PASS_COUNT=$((PASS_COUNT+1))
    $SSH "sudo modprobe $MOD" >/dev/null 2>&1 || true
    assert "modprobe loaded it: it is in lsmod" bash -c "$SSH 'lsmod | grep -q \"^$MOD \"'"
    assert "and it appears under /sys/module" bash -c "$SSH 'test -d /sys/module/$MOD'"
    mi=$($SSH "modinfo $MOD 2>/dev/null | head -5" || true)
    assert_contains "modinfo describes it (filename/description)" "$mi" "filename|description"
    $SSH "sudo modprobe -r $MOD" >/dev/null 2>&1 || true
    refute "modprobe -r removed it from lsmod" bash -c "$SSH 'lsmod | grep -q \"^$MOD \"'"
else
    log_fail "no loadable module found on this kernel — the module half of sys-03 has no ground here"
    FAIL_COUNT=$((FAIL_COUNT+1))
fi

# --- 7. teardown -----------------------------------------------------------------
log_info "Tearing down (remove the sysctl drop-in)..."
$SSH "sudo rm -f /etc/sysctl.d/99-lab.conf" >/dev/null 2>&1 || true
refute "the drop-in is gone" bash -c "$SSH 'test -f /etc/sysctl.d/99-lab.conf'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-03: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
