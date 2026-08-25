#!/usr/bin/env bash
# sys-07 — Diagnostics and performance.
#
# The invariant: the machine has ONE of several possible faults, and the check
# demands the right CLASSIFICATION first — read from live metrics, never from
# the seed — and only then the cure. Observe -> measure -> fix -> measure again.
# No reboot here: this chapter is about the living system.
#
# The classifier is tested in BOTH directions (the zero has two readings): it
# must say "sano" on a healthy machine before any fault is seeded, and again
# after every cure — a classifier that cries wolf is as useless as a blind one.
#
# Three fault classes, exercised in a seed-rotated order:
#   cpu      — a runaway busy-loop        (a process eating >80% of a core)
#   memoria  — a bounded memory hog       (MemAvailable below 25% of MemTotal)
#   disco    — a filesystem filled solid  (a mount at 100%)
#
# Every cure is measurement-driven too: kill the top-CPU pid, kill the top-RSS
# pid, remove the biggest file on the full mount — never "kill the thing whose
# name I happen to know".
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

SEED=$(date +%s)
CLASSI=(cpu memoria disco)
MP="/srv/dati"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-07 — diagnostics and performance${RESET}"; echo ""

# The classifier: live metrics only. Order matters — a full disk does not raise
# the load, a sleeping hog does not eat CPU.
classifica() {
    if $SSH 'df -x tmpfs -x devtmpfs --output=pcent 2>/dev/null | grep -q "100%"' >/dev/null 2>&1; then echo disco; return; fi
    if $SSH 'awk "/MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{exit !(a*4<t)}" /proc/meminfo' >/dev/null 2>&1; then echo memoria; return; fi
    if $SSH 'ps -eo pcpu= --sort=-pcpu | head -1 | awk "{exit !(\$1>80)}"' >/dev/null 2>&1; then echo cpu; return; fi
    echo sano
}

semina() {
    case "$1" in
        cpu)     $SSH 'setsid sh -c "while :; do :; done" >/dev/null 2>&1 < /dev/null &' >/dev/null 2>&1 || true; sleep 9 ;;
        memoria) $SSH 'setsid python3 -c "import time; b=bytearray(650*1024*1024); time.sleep(600)" >/dev/null 2>&1 < /dev/null &' >/dev/null 2>&1 || true; sleep 7 ;;
        disco)   $SSH "sudo dd if=/dev/zero of=$MP/riempitivo.bin bs=1M >/dev/null 2>&1 || true" >/dev/null 2>&1 || true; sleep 1 ;;
    esac
}

cura() {
    case "$1" in
        cpu)     $SSH 'ps -eo pid=,pcpu= --sort=-pcpu | awk "\$2>80{print \$1}" | xargs -r sudo kill -9' >/dev/null 2>&1 || true; sleep 2 ;;
        memoria) $SSH 'ps -eo pid=,rss= --sort=-rss | head -1 | awk "\$2>300000{print \$1}" | xargs -r sudo kill -9' >/dev/null 2>&1 || true; sleep 2 ;;
        disco)   $SSH 'f=$(sudo find '"$MP"' -xdev -type f -printf "%s %p\n" 2>/dev/null | sort -n | tail -1 | cut -d" " -f2-); [ -n "$f" ] && sudo rm -f "$f"' >/dev/null 2>&1 || true; sleep 1 ;;
    esac
}

# --- boot + world -------------------------------------------------------------
log_info "Booting the target..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT"
assert "target answers SSH" banco_wait_ssh "$SSH" 200

log_info "World: a small data filesystem on /dev/vdb1, mounted at $MP..."
$SSH "sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo sgdisk -n 1:0:0 /dev/vdb >/dev/null 2>&1; sudo partprobe /dev/vdb 2>/dev/null; sleep 1; sudo mkfs.ext4 -q -F /dev/vdb1 >/dev/null 2>&1; sudo mkdir -p $MP && sudo mount /dev/vdb1 $MP" >/dev/null 2>&1 || true
assert "the data filesystem is mounted" bash -c "$SSH 'findmnt -rno TARGET $MP'"

# --- the classifier must not cry wolf ------------------------------------------
v=$(classifica)
if [[ "$v" == "sano" ]]; then log_ok "healthy baseline classified as 'sano' (the classifier does not cry wolf)"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "baseline misclassified as '$v'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi

# --- three faults, seed-rotated order -------------------------------------------
for i in 0 1 2; do
    c="${CLASSI[$(( (SEED + i) % 3 ))]}"
    log_info "Fault '$c': seeding, classifying from live metrics, curing..."
    semina "$c"
    v=$(classifica)
    if [[ "$v" == "$c" ]]; then log_ok "classified correctly: $v"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "classified '$v', the seeded fault was '$c'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
    cura "$c"
    v=$(classifica)
    if [[ "$v" == "sano" ]]; then log_ok "cured: back to 'sano', measured"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "after the cure the classifier still says '$v'"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
done

# --- teardown --------------------------------------------------------------------
log_info "Tearing down (unmount, wipe the data disk)..."
$SSH "sudo umount $MP 2>/dev/null; sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo wipefs -a /dev/vdb >/dev/null 2>&1; sudo rmdir $MP 2>/dev/null" >/dev/null 2>&1 || true
refute "nothing is mounted at $MP any more" bash -c "$SSH 'findmnt -rno TARGET $MP'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-07: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
