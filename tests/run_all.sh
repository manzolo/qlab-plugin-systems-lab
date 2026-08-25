#!/usr/bin/env bash
# systems-lab test runner. Each test_NN drives the target through the bench.
# They are heavier than the other plugins' tests (a test power-cycles a real VM),
# so they run sequentially and can take a few minutes each.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOLD=$'\033[1m'; RESET=$'\033[0m'
echo ""; echo "${BOLD}=========================================${RESET}"
echo "${BOLD}  systems-lab — Automated Test Suite${RESET}"
echo "${BOLD}  (the boot IS the test)${RESET}"
echo "${BOLD}=========================================${RESET}"

total_fail=0
for t in "$TESTS_DIR"/test_*.sh; do
    [[ -f "$t" ]] || continue
    bash "$t" || total_fail=$((total_fail + $?))
done

echo ""
if [[ "$total_fail" -eq 0 ]]; then
    echo "${BOLD}All systems-lab tests passed.${RESET}"
else
    echo "${BOLD}systems-lab: ${total_fail} assertion(s) failed.${RESET}"
fi
exit "$total_fail"
