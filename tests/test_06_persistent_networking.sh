#!/usr/bin/env bash
# sys-06 — Persistent networking.
#
# The invariant, in the two acts that ARE the lesson:
#
#   Act 1 — what `ip addr add` gives you EVAPORATES: set an address by hand on
#           the lab NIC, power-cycle, and it is gone. Never trust the state the
#           `ip` commands leave behind.
#   Act 2 — what netplan/systemd-networkd owns COMES BACK: the same address,
#           plus a static route and a DNS server, configured in a netplan file
#           that matches the NIC by MAC (identity, not name), survive a real
#           power-cycle — and address, route and DNS are measured SEPARATELY,
#           each from the live system, never from the file alone.
#
# The lab NIC is a second virtio interface on an isolated mcast LAN (no DHCP,
# no peers, no way out): whatever appears on it was configured, not leased.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

# Run-varying third octet, valid range 10-99.
OCT=$((10 + $(date +%s) % 90))
ADDR="10.99.$OCT.1"
ROUTE_TO="10.88.$OCT.0/24"; ROUTE_VIA="10.99.$OCT.254"
DNS_IP="10.99.$OCT.53"
LAB_MAC="52:54:00:00:13:01"
LAN_ARGS=(-netdev "socket,id=lan1,mcast=230.0.0.19:10219" -device "virtio-net-pci,netdev=lan1,mac=$LAB_MAC")
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

echo ""; echo "${BOLD}sys-06 — persistent networking${RESET}"; echo ""

log_info "Booting the target with a second NIC on an isolated LAN (mac $LAB_MAC)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT" "${LAN_ARGS[@]}"
assert "target answers SSH" banco_wait_ssh "$SSH" 200
NIC=$($SSH "ip -o link | grep -i '$LAB_MAC' | awk -F': ' '{print \$2}'" 2>/dev/null | tr -d '\r\n ' || true)
if [[ -n "$NIC" ]]; then log_ok "the lab NIC exists: $NIC (found by MAC — identity, not name)"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "no NIC with mac $LAB_MAC"; FAIL_COUNT=$((FAIL_COUNT+1)); fi

# --- Act 1: runtime state evaporates ------------------------------------------
log_info "Act 1: setting $ADDR by hand with ip(8), then power-cycling..."
$SSH "sudo ip link set $NIC up && sudo ip addr add $ADDR/24 dev $NIC" >/dev/null 2>&1 || true
assert "the hand-made address is live now" bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"
assert "target came back on a NEW boot" banco_reboot_wait_newboot "$SSH" 220
refute "and the hand-made address is GONE (runtime state evaporates)" \
    bash -c "$SSH 'ip -o addr show dev $NIC 2>/dev/null | grep -q $ADDR/'"

# --- Act 2: persistent configuration comes back --------------------------------
log_info "Act 2: the same address via netplan/systemd-networkd (matched by MAC)..."
$SSH "sudo tee /etc/netplan/60-lab.yaml >/dev/null && sudo chmod 600 /etc/netplan/60-lab.yaml" <<EOF || true
network:
  version: 2
  ethernets:
    labnic:
      match:
        macaddress: "$LAB_MAC"
      addresses:
        - $ADDR/24
      routes:
        - to: $ROUTE_TO
          via: $ROUTE_VIA
      nameservers:
        addresses: [$DNS_IP]
EOF
assert "the netplan file carries the seeded address" \
    bash -c "$SSH 'sudo grep -q $ADDR/24 /etc/netplan/60-lab.yaml'"
$SSH "sudo netplan apply" >/dev/null 2>&1 || true
sleep 3
assert "address live after netplan apply" bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"

log_info "Power-cycling: address, route and DNS must come back BY THEMSELVES..."
assert "target came back on a NEW boot" banco_reboot_wait_newboot "$SSH" 220
assert "the ADDRESS is back, measured live (ip addr)" \
    bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"
assert "the ROUTE is back, measured live (ip route)" \
    bash -c "$SSH 'ip route show | grep -q \"$ROUTE_TO via $ROUTE_VIA\"'"
dns_out=$($SSH "resolvectl dns $NIC 2>/dev/null" || true)
assert_contains "the DNS server is back, measured live (resolvectl, not the file)" "$dns_out" "$DNS_IP"

# --- teardown -------------------------------------------------------------------
log_info "Tearing down (remove the netplan file)..."
$SSH "sudo rm -f /etc/netplan/60-lab.yaml && sudo netplan apply" >/dev/null 2>&1 || true
refute "the netplan file is gone" bash -c "$SSH 'test -f /etc/netplan/60-lab.yaml'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-06: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
