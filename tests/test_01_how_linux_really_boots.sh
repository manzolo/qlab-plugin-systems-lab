#!/usr/bin/env bash
# sys-01 — How Linux really boots.
#
# The invariant, and why /proc/cmdline is the honest place to read it: a kernel
# parameter you set in GRUB does nothing until the machine is rebooted THROUGH
# GRUB with it. So the proof is not "the line is in /etc/default/grub" — it is
# that the running kernel, after a real power-cycle, carries the parameter in
# /proc/cmdline. This test:
#
#   1. boots the target, confirms the marker is NOT there yet
#   2. adds a required kernel parameter via GRUB (the reference solution)
#   3. power-cycles the machine
#   4. reads /proc/cmdline: the parameter is now there — it BOOTED with it
#   5. shows the same fact where a student would read it: journalctl -b / dmesg
#   6. reverts the change, so the overlay returns to baseline for other tests
#
# The parameter value is chosen at run time (not hardcodable): the check greps
# for exactly that value.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

# A run-varying marker so a naive "just echo the expected string" cannot pass.
TOKEN="labboot$(date +%s | tail -c 6)"
MARKER="lab_marker=$TOKEN"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-01 — how Linux really boots${RESET}"; echo ""

# --- 1. clean baseline ------------------------------------------------------
log_info "Booting the target..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200
refute "the marker is NOT on the kernel cmdline yet" bash -c "$SSH 'grep -q $MARKER /proc/cmdline'"

# --- 2. add the parameter via GRUB (reference solution) ---------------------
# The trap this cloud image teaches: /etc/default/grub.d/50-cloudimg-settings.cfg
# is sourced AFTER /etc/default/grub and OVERRIDES GRUB_CMDLINE_LINUX_DEFAULT — so
# editing the main file alone does nothing (the running cmdline here does not even
# carry the "quiet splash" that /etc/default/grub sets). The parameter has to be
# appended by a drop-in that runs last. (Learned live, 2026-08-25.)
log_info "Adding $MARKER via a /etc/default/grub.d drop-in and regenerating grub.cfg..."
$SSH "echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT $MARKER\"' | sudo tee /etc/default/grub.d/99-lab.cfg >/dev/null" >/dev/null 2>&1
assert "the parameter is in the grub.d drop-in" bash -c "$SSH 'grep -q $MARKER /etc/default/grub.d/99-lab.cfg'"
$SSH "sudo update-grub >/dev/null 2>&1" >/dev/null 2>&1
assert "the parameter reached the generated grub.cfg" bash -c "$SSH 'sudo grep -q $MARKER /boot/grub/grub.cfg'"

# --- 3. power-cycle ---------------------------------------------------------
log_info "Rebooting so the machine boots THROUGH GRUB with the new cmdline..."
assert "target came back on a NEW boot (boot_id changed)" banco_reboot_wait_newboot "$SSH" 220

# --- 4. the honest proof: it BOOTED with the parameter ----------------------
assert "the kernel booted WITH the parameter (/proc/cmdline)" bash -c "$SSH 'grep -q $MARKER /proc/cmdline'"

# --- 5. show it where a student reads it ------------------------------------
# The kernel logs its command line at boot; journalctl -b / dmesg show it.
# dmesg is restricted (kernel.dmesg_restrict) on this image, so it needs sudo.
jb=$($SSH "sudo journalctl -b 2>/dev/null | grep -m1 'Command line' || sudo dmesg 2>/dev/null | grep -m1 'Command line' || true")
assert_contains "the boot log shows the same cmdline (journalctl -b / dmesg)" "$jb" "$TOKEN"

# --- 6. revert to baseline --------------------------------------------------
log_info "Reverting the GRUB change (leave the overlay at baseline)..."
$SSH "sudo rm -f /etc/default/grub.d/99-lab.cfg && sudo update-grub >/dev/null 2>&1" >/dev/null 2>&1
refute "the drop-in is gone and the marker is out of grub.cfg" bash -c "$SSH 'sudo grep -q $MARKER /boot/grub/grub.cfg'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-01: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
