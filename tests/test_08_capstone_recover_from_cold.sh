#!/usr/bin/env bash
# sys-08 (FULL capstone) — Recover a machine that won't start.
#
# Four chained faults across every layer the track teaches, and a check that
# starts from a POWERED-OFF machine — "the reboot cannot be simulated by
# reading files": only cold boots prove the machine actually comes back.
#
#   A. boot     — a bad /etc/fstab line, no nofail   -> the boot stops at emergency
#   B. storage  — the DATA mount's UUID is wrong (but nofail) -> boot proceeds,
#                 the filesystem silently does not mount
#   C. service  — lab.service is disabled, and even enabled it REQUIRES the
#                 data mount (RequiresMountsFor): it only lives when B is fixed
#   D. network  — the persistent netplan config carries the WRONG address
#
# The layering is the lesson: A hides everything; fixing A reveals B, C, D,
# each visible only by MEASURING (findmnt, systemctl, ip addr). The final
# heartbeat is the token read from the REAL data mount and copied to /run
# (a tmpfs) by the service — one file that proves boot + storage + service in
# a single measurement, on a fresh power-cycle.
#
# Declared out of scope (honestly): a "required module" fault (nothing on this
# VM makes a module load-bearing — the module lesson lives in sys-03) and a
# firewall fault (needs an external prober; the bench has no LAN peer).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$TESTS_DIR/_common.sh"

NOW=$(date +%s)
TOKEN="capstone${NOW}"
OCT=$((10 + NOW % 90))
ADDR="10.99.$OCT.1"; WRONG_ADDR="10.99.$OCT.66"
LAB_MAC="52:54:00:00:13:01"
LAN_ARGS=(-netdev "socket,id=lan1,mcast=230.0.0.19:10219" -device "virtio-net-pci,netdev=lan1,mac=$LAB_MAC")
BAD_UUID="dead0008-dead-dead-dead-deaddead0008"
WRONG_UUID="beef0008-beef-beef-beef-beefbeef0008"
MP="/srv/dati"
TLOG="$BENCH_DIR/target.log"; TPID="$BENCH_DIR/target.pid"; TPORT=2288
SSH="$(banco_ssh "$SSH_KEY" "$TPORT")"

netplan_write() {  # $1 = address to configure
    $SSH "sudo tee /etc/netplan/60-lab.yaml >/dev/null && sudo chmod 600 /etc/netplan/60-lab.yaml" <<EOF || true
network:
  version: 2
  ethernets:
    labnic:
      match:
        macaddress: "$LAB_MAC"
      addresses:
        - $1/24
EOF
}

echo ""; echo "${BOLD}sys-08 — FULL capstone: recover a machine that won't start (from cold)${RESET}"; echo ""

# --- 1. build the world ---------------------------------------------------------
log_info "Booting the target and building the world (data fs + service + network)..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT" "${LAN_ARGS[@]}"
assert "target answers SSH" banco_wait_ssh "$SSH" 200

$SSH "sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo sgdisk -n 1:0:0 /dev/vdb >/dev/null 2>&1; sudo partprobe /dev/vdb 2>/dev/null; sleep 1; sudo mkfs.ext4 -q -F /dev/vdb1 >/dev/null 2>&1" >/dev/null 2>&1 || true
UUID=$($SSH "sudo blkid -o value -s UUID /dev/vdb1 2>/dev/null" | tr -d '\r\n ')
assert "the data filesystem exists and has a UUID" bash -c "[[ -n '$UUID' ]]"
$SSH "sudo mkdir -p $MP && echo 'UUID=$UUID $MP ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab >/dev/null && sudo mount -a && echo '$TOKEN' | sudo tee $MP/token.txt >/dev/null" >/dev/null 2>&1 || true
assert "the data mount is live and carries the token" bash -c "$SSH 'grep -q $TOKEN $MP/token.txt'"

$SSH "sudo tee /etc/systemd/system/lab.service >/dev/null" <<UNIT || true
[Unit]
Description=Lab data service (lives only if the data mount lives)
RequiresMountsFor=$MP

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cp $MP/token.txt /run/lab-heartbeat'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
$SSH "sudo systemctl daemon-reload && sudo systemctl enable --now lab.service" >/dev/null 2>&1 || true
# is-active photographed right after `enable --now` races the oneshot's own
# ExecStart (seen live, 2026-08-25): wait for the verdict, don't photograph it.
ok_svc=1
for _ in $(seq 1 10); do
    $SSH "systemctl is-active lab.service >/dev/null && grep -q $TOKEN /run/lab-heartbeat" >/dev/null 2>&1 && { ok_svc=0; break; }
    sleep 2
done
if [[ "$ok_svc" -eq 0 ]]; then log_ok "the service is alive and its heartbeat IS the token from the mount"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "the service never came alive with the token heartbeat"; FAIL_COUNT=$((FAIL_COUNT+1)); fi

netplan_write "$ADDR"
$SSH "sudo netplan apply" >/dev/null 2>&1 || true; sleep 3
NIC=$($SSH "ip -o link | grep -i '$LAB_MAC' | awk -F': ' '{print \$2}'" 2>/dev/null | tr -d '\r\n ' || true)
assert "the persistent network is up on the lab NIC ($NIC)" bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"

# --- 2. seed the four chained faults, then power OFF ------------------------------
log_info "Seeding the four faults (A boot, B storage, C service, D network), powering off..."
$SSH "echo 'UUID=$BAD_UUID /srv/blocco ext4 defaults 0 2' | sudo tee -a /etc/fstab >/dev/null" >/dev/null 2>&1 || true
assert "fault A landed: the boot-blocker line is in fstab" bash -c "$SSH 'grep -q $BAD_UUID /etc/fstab'"
$SSH "sudo sed -i 's|UUID=$UUID|UUID=$WRONG_UUID|' /etc/fstab" >/dev/null 2>&1 || true
assert "fault B landed: the data mount now points at a UUID that does not exist" \
    bash -c "$SSH 'grep -q $WRONG_UUID /etc/fstab'"
$SSH "sudo systemctl disable --now lab.service" >/dev/null 2>&1 || true
assert "fault C landed: lab.service is disabled" \
    bash -c "$SSH 'systemctl is-enabled lab.service 2>&1 | grep -q disabled'"
netplan_write "$WRONG_ADDR"
assert "fault D landed: the netplan file carries the wrong address" \
    bash -c "$SSH 'sudo grep -q $WRONG_ADDR/24 /etc/netplan/60-lab.yaml'"
assert "the machine powered off by itself (COLD)" banco_poweroff_wait "$SSH" "$TPID" 90

# --- 3. cold boot #1: fault A hides everything -------------------------------------
log_info "Cold boot #1: the machine does not come up..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT" "${LAN_ARGS[@]}"
ok_emerg=1
for _ in $(seq 1 80); do
    grep -aqE "$BANCO_EMERGENCY_RE" "$TLOG" && { ok_emerg=0; break; }
    sleep 3
done
if [[ "$ok_emerg" -eq 0 ]]; then log_ok "cold boot stops at emergency (serial)"; PASS_COUNT=$((PASS_COUNT+1)); else log_fail "no emergency markers on the cold boot"; FAIL_COUNT=$((FAIL_COUNT+1)); fi
refute "SSH is down on the broken machine" bash -c "$SSH true"
banco_stop_pid "$TPID"

# --- 4. rescue: fix ONLY the boot blocker -------------------------------------------
log_info "Rescue: remove the boot blocker (and nothing else — the rest is diagnosed alive)..."
repair="sudo mount /dev/vdb1 /mnt && sudo sed -i '\\|/srv/blocco|d' /mnt/etc/fstab && echo REMAINING=\$(grep -c $BAD_UUID /mnt/etc/fstab || echo 0) && sudo umount /mnt"
out="$(banco_rescue_run "$BASE_IMAGE" "$TARGET_OVERLAY" "$SSH_KEY" "$repair" 2299 "$RESCUE_CIDATA" || true)"
assert_contains "rescue removed the boot blocker" "$out" "REMAINING=0"

# --- 5. cold boot #2: the machine is back, the OTHER faults emerge one by one --------
log_info "Cold boot #2: measuring what is still wrong..."
: > "$TLOG"
banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TLOG" "$TPID" "$TPORT" "${LAN_ARGS[@]}"
assert "the machine reaches SSH again" banco_wait_ssh "$SSH" 200
refute "fault B is visible: the data mount is absent" bash -c "$SSH 'findmnt -rno TARGET $MP'"
refute "fault C is visible: the service is dead" bash -c "$SSH 'systemctl is-active lab.service >/dev/null'"
assert "fault D is visible: the lab NIC carries the WRONG address" \
    bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $WRONG_ADDR/'"

log_info "Curing in order: storage -> service -> network..."
$SSH "real=\$(sudo blkid -o value -s UUID /dev/vdb1) && sudo sed -i \"s|UUID=$WRONG_UUID|UUID=\$real|\" /etc/fstab && sudo systemctl daemon-reload && sudo mount -a" >/dev/null 2>&1 || true
assert "storage cured: the data mount is back (UUID read from the disk, not guessed)" \
    bash -c "$SSH 'findmnt -rno TARGET $MP'"
$SSH "sudo systemctl enable --now lab.service" >/dev/null 2>&1 || true
assert "service cured: alive, heartbeat is the token from the real mount" \
    bash -c "$SSH 'systemctl is-active lab.service >/dev/null && grep -q $TOKEN /run/lab-heartbeat'"
netplan_write "$ADDR"
$SSH "sudo netplan apply" >/dev/null 2>&1 || true; sleep 3
assert "network cured: the RIGHT address is live" bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"

# --- 6. the final proof: one more power-cycle, EVERYTHING comes back by itself -------
log_info "Final power-cycle: every layer must survive a fresh boot..."
assert "machine came back on a NEW boot" banco_reboot_wait_newboot "$SSH" 220
assert "storage survives: the data mount returned by itself" bash -c "$SSH 'findmnt -rno TARGET $MP'"
assert "service survives: it ran on THIS boot (token in /run, a tmpfs)" \
    bash -c "$SSH 'systemctl is-active lab.service >/dev/null && grep -q $TOKEN /run/lab-heartbeat'"
assert "network survives: the right address returned by itself" \
    bash -c "$SSH 'ip -o addr show dev $NIC | grep -q $ADDR/'"
refute "and no fault left a trace in fstab" bash -c "$SSH 'grep -qE \"$BAD_UUID|$WRONG_UUID\" /etc/fstab'"

# --- 7. teardown to baseline -----------------------------------------------------------
log_info "Tearing down (service, netplan, fstab, data disk)..."
$SSH "sudo systemctl disable --now lab.service >/dev/null 2>&1; sudo rm -f /etc/systemd/system/lab.service /etc/netplan/60-lab.yaml; sudo systemctl daemon-reload; sudo netplan apply >/dev/null 2>&1; sudo umount $MP 2>/dev/null; sudo sed -i '\\|$MP|d' /etc/fstab; sudo sgdisk --zap-all /dev/vdb >/dev/null 2>&1; sudo wipefs -a /dev/vdb >/dev/null 2>&1; sudo rmdir $MP 2>/dev/null" >/dev/null 2>&1 || true
refute "fstab no longer references $MP" bash -c "$SSH 'grep -q \"$MP\" /etc/fstab'"
banco_stop_pid "$TPID"

echo ""
echo "  ${BOLD}sys-08: ${PASS_COUNT} passed, ${FAIL_COUNT} failed${RESET}"
exit "$FAIL_COUNT"
