#!/usr/bin/env bash
# Shared test harness for systems-lab. Unlike the other qlab plugins, these tests
# do NOT just ssh into a qlab-managed VM: they need to power-cycle the target and
# keep the same overlay across the cycle, so they drive it through the bench
# (lib/banco.sh) with plain qemu. See lib/banco.sh for why.
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
PASS_COUNT=0; FAIL_COUNT=0
log_ok()   { printf "${GREEN}  [PASS]${RESET} %s\n" "$*"; }
log_fail() { printf "${RED}  [FAIL]${RESET} %s\n" "$*"; }
log_info() { printf "${YELLOW}  [INFO]${RESET} %s\n" "$*"; }
assert()          { local d="$1"; shift; if "$@" >/dev/null 2>&1; then log_ok "$d"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "$d"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }
refute()          { local d="$1"; shift; if "$@" >/dev/null 2>&1; then log_fail "$d"; FAIL_COUNT=$((FAIL_COUNT+1)); else log_ok "$d"; PASS_COUNT=$((PASS_COUNT+1)); fi; }
assert_contains() { local d="$1" o="$2" p="$3"; if echo "$o"|grep -qE "$p"; then log_ok "$d"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "$d (expected: $p)"; FAIL_COUNT=$((FAIL_COUNT+1)); fi; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Find the workspace: the directory that contains .qlab.
_find_workspace() {
    local d="$PLUGIN_DIR"
    if [[ -d "$d/../../.qlab" ]]; then (cd "$d/../.." && pwd); return; fi
    while [[ "$d" != "/" ]]; do [[ -d "$d/.qlab" ]] && { echo "$d"; return; }; d="$(dirname "$d")"; done
    echo ""
}
WORKSPACE_DIR="$(_find_workspace)"
[[ -n "$WORKSPACE_DIR" ]] || { echo "ERROR: cannot find qlab workspace (.qlab). Run 'qlab run systems-lab' first."; exit 1; }
export WORKSPACE_DIR

# shellcheck source=/dev/null
source "$PLUGIN_DIR/lib/banco.sh"

BASE_IMAGE="$WORKSPACE_DIR/.qlab/images/ubuntu-22.04-minimal-cloudimg-amd64.img"
SSH_KEY="$WORKSPACE_DIR/.qlab/ssh/qlab_id_rsa"
TARGET_OVERLAY="$PLUGIN_DIR/lab/systems-lab-target-disk.qcow2"
TARGET_DATA="$PLUGIN_DIR/lab/systems-lab-data.qcow2"
CIDATA_ISO="$PLUGIN_DIR/lab/cidata-target.iso"

for f in "$BASE_IMAGE" "$SSH_KEY" "$TARGET_OVERLAY"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f. Run 'qlab run systems-lab' once to provision the target, then re-run the tests."; exit 1; }
done

# The bench drives the target's disk directly and needs exclusive access, so a
# qlab-managed target must be stopped first. `qlab test` satisfies its own
# "a VM must be running" guard because the target WAS running when it was invoked
# (the guard checks before this script runs); we then release the disk here.
if command -v qlab >/dev/null 2>&1; then
    qlab stop systems-lab >/dev/null 2>&1 || true
    sleep 2
fi

# Scratch space for bench serial logs and pidfiles.
BENCH_DIR="$(mktemp -d)"
trap 'banco_stop_pid "$BENCH_DIR/target.pid" 2>/dev/null || true; rm -rf "$BENCH_DIR"' EXIT
