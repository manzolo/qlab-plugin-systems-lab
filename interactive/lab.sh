#!/usr/bin/env bash
# qlab-lab — the interactive front-end for systems-lab.
#
# The monolithic `qlab test` seeds a fault, fixes it, and checks, all in one
# breath: perfect for CI, useless for a person. This driver splits the three
# moves so a HUMAN sits in the middle — seed the fault, hand the machine over,
# grade what they did — and hides the seed HOST-SIDE, where the student (even
# from the rescue) cannot read it.
#
#   qlab-lab list
#   qlab-lab start  <chapter>     seed the fault, prepare the machine, show the brief
#   qlab-lab rescue               boot a rescue system with the (stopped) disk attached
#   qlab-lab check  <chapter>     boot the machine and grade it — no fixing
#   qlab-lab hint   <chapter> [n]
#   qlab-lab solve  <chapter>     apply the reference fix (for checking the lab itself)
#   qlab-lab reset  <chapter>     seed a fresh fault
#   qlab-lab stop                 power everything off
#
# It reuses the bench (lib/banco.sh): serial oracle, persistent boot, QMP
# hot-plug rescue. Nothing here re-invents what the tests already proved.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
CH_DIR="$HERE/chapters"

_find_ws() { local d="$PLUGIN_DIR"; if [[ -d "$d/../../.qlab" ]]; then (cd "$d/../.." && pwd); return; fi
    while [[ "$d" != "/" ]]; do [[ -d "$d/.qlab" ]] && { echo "$d"; return; }; d="$(dirname "$d")"; done; echo ""; }
WORKSPACE_DIR="$(_find_ws)"
[[ -n "$WORKSPACE_DIR" ]] || { echo "Nessun workspace .qlab. Lancia prima: qlab run systems-lab"; exit 1; }
export WORKSPACE_DIR
# shellcheck source=/dev/null
source "$PLUGIN_DIR/lib/banco.sh"

BASE_IMAGE="$WORKSPACE_DIR/.qlab/images/ubuntu-22.04-server-cloudimg-amd64.img"
SSH_KEY="$WORKSPACE_DIR/.qlab/ssh/qlab_id_rsa"
TARGET_OVERLAY="$PLUGIN_DIR/lab/systems-lab-target-disk.qcow2"
TARGET_DATA="$PLUGIN_DIR/lab/systems-lab-data.qcow2"
RESCUE_CIDATA="$PLUGIN_DIR/lab/cidata-rescue.iso"; [[ -f "$RESCUE_CIDATA" ]] || RESCUE_CIDATA="$PLUGIN_DIR/lab/cidata-target.iso"
LAB_DIR="$PLUGIN_DIR/lab"
LAB_PORT=2288
TARGET_LOG="$LAB_DIR/.lab-target.log"
TARGET_PID="$LAB_DIR/.lab-target.pid"

for f in "$BASE_IMAGE" "$SSH_KEY" "$TARGET_OVERLAY"; do
    [[ -f "$f" ]] || { echo "Manca $f — lancia prima: qlab run systems-lab (attendi il provisioning, poi qlab stop systems-lab)"; exit 1; }
done
# The bench owns the disk: a qlab-managed target would fight for it.
command -v qlab >/dev/null 2>&1 && { qlab stop systems-lab >/dev/null 2>&1 || true; }

# Serial-log basename the banco helpers key on (banco reads $WORKSPACE_DIR/.qlab/logs/<vm>.log).
# Here we drive our own log path, so wrap the two oracle checks against TARGET_LOG.
banco_serial_has()  { grep -aqE "$2" "$TARGET_LOG" 2>/dev/null; }   # override: our log path
banco_boot_clean()  { local t="${2:-150}" w=0; while [[ $w -lt $t ]]; do grep -aqE "$BANCO_LOGIN_RE" "$TARGET_LOG" 2>/dev/null && return 0; sleep 3; w=$((w+3)); done; return 1; }
banco_boot_broke()  { local t="${2:-150}" w=0; while [[ $w -lt $t ]]; do grep -aqE "$BANCO_EMERGENCY_RE" "$TARGET_LOG" 2>/dev/null && return 0; sleep 3; w=$((w+3)); done; return 1; }

lab_stop_target() { banco_stop_pid "$TARGET_PID"; }

lab_boot_target_fresh() {   # boot the persistent overlay (carries seed / student's repair)
    lab_stop_target; sleep 1; : > "$TARGET_LOG"
    banco_boot_target "$TARGET_OVERLAY" "$TARGET_DATA" "$TARGET_LOG" "$TARGET_PID" "$LAB_PORT"
}

_seed_file() { echo "$LAB_DIR/.lab-seed-$1"; }   # host-side hidden seed, per chapter

_load_chapter() {
    local ch="$1"; local f="$CH_DIR/$ch.sh"
    [[ -f "$f" ]] || { echo "Capitolo sconosciuto: $ch. Prova: qlab-lab list"; exit 1; }
    SEED_FILE="$(_seed_file "$ch")"
    # shellcheck source=/dev/null
    source "$f"
}

cmd_list() {
    echo "Capitoli di systems-lab (interattivi):"
    for f in "$CH_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        local id; id="$(basename "$f" .sh)"
        ( source "$f"; printf "  %-8s %s\n" "$id" "${CH_TITLE:-}" )
    done
}

cmd_start() {
    local ch="$1"; _load_chapter "$ch"
    echo "▶ Preparo «$CH_TITLE» ($ch)…"
    lab_boot_target_fresh
    local ssh; ssh="$(banco_ssh "$SSH_KEY" "$LAB_PORT")"
    banco_wait_ssh "$ssh" 200 || { echo "La macchina non si è avviata pulita: prova 'qlab run systems-lab' e riprova."; lab_stop_target; exit 1; }
    ch_seed "$ssh"
    if [[ "${CH_NEEDS_RESCUE:-0}" = 1 ]]; then
        # break it: reboot into the fault, confirm on the serial, then power off.
        local before; before=$(wc -l < "$TARGET_LOG")
        banco_reboot_guest "$ssh"
        if ! ( w=0; while [[ $w -lt 200 ]]; do tail -n +"$((before+1))" "$TARGET_LOG" | grep -aqE "$BANCO_EMERGENCY_RE" && exit 0; sleep 3; w=$((w+3)); done; exit 1 ); then
            echo "⚠ Il guasto non ha fermato il boot come atteso (segnalalo)."
        fi
        lab_stop_target
    fi
    echo ""; ch_brief; echo ""
    echo "  Quando pensi di aver risolto:  qlab-lab check $ch"
}

# lab_rescue [--run "cmd"]  — target must be stopped; boot rescue, hot-plug the
# target disk as /dev/vdb, then either exec ssh (interactive) or run a command.
lab_rescue() {
    local run_cmd=""; [[ "${1:-}" == "--run" ]] && { run_cmd="$2"; }
    lab_stop_target; sleep 1
    local work; work="$(mktemp -d)"; local rd="$work/rescue.qcow2" rp="$work/rescue.pid"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$rd" >/dev/null 2>&1
    local kvm=(); [[ -e /dev/kvm && -w /dev/kvm ]] && kvm=(-enable-kvm -cpu host)
    local cd=(); [[ -f "$RESCUE_CIDATA" ]] && cd=(-cdrom "$RESCUE_CIDATA")
    local port=2299
    qemu-system-x86_64 -m 1024 -smp 1 -display none -monitor none -daemonize \
        -pidfile "$rp" -serial "file:$work/rescue.log" -qmp "unix:$work/qmp.sock,server,nowait" \
        -drive "file=$rd,format=qcow2,if=virtio" "${cd[@]}" \
        -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${port}-:22" -device virtio-net-pci,netdev=n0 "${kvm[@]}"
    local ssh="ssh -i $SSH_KEY -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o IdentitiesOnly=yes labuser@127.0.0.1"
    local up=1 w=0; while [[ $w -lt 200 ]]; do $ssh true >/dev/null 2>&1 && { up=0; break; }; sleep 4; w=$((w+4)); done
    [[ $up -eq 0 ]] || { echo "La soccorso non è salita."; banco_stop_pid "$rp"; rm -rf "$work"; return 1; }
    _banco_qmp_hmp "$work/qmp.sock" "drive_add 0 if=none,file=$TARGET_OVERLAY,format=qcow2,id=tgt" >/dev/null 2>&1 || true
    _banco_qmp_hmp "$work/qmp.sock" "device_add virtio-blk-pci,drive=tgt,id=tgtdev" >/dev/null 2>&1 || true
    w=0; while [[ $w -lt 40 ]]; do $ssh "test -b /dev/vdb" >/dev/null 2>&1 && break; sleep 2; w=$((w+2)); done
    local rc=0
    if [[ -n "$run_cmd" ]]; then $ssh "$run_cmd"; rc=$?; $ssh "sudo poweroff" >/dev/null 2>&1 || true
    else
        echo "  Soccorso pronta. Il disco della macchina rotta è /dev/vdb (root: /dev/vdb1)."
        echo "  Riparalo, poi 'sudo poweroff'. Al ritorno: qlab-lab check <capitolo>."
        $ssh || true
    fi
    banco_stop_pid "$rp"; rm -rf "$work"; return "$rc"
}

cmd_check() {
    local ch="$1"; _load_chapter "$ch"
    echo "▶ Verifico «$CH_TITLE» ($ch)…"
    if ch_check; then echo ""; echo "  ✅ SUPERATO."; lab_stop_target; return 0
    else echo ""; echo "  ❌ Non ancora. Riprova, o: qlab-lab hint $ch"; lab_stop_target; return 1; fi
}

cmd_solve() {   # reference fix — for checking the lab itself, not for students
    local ch="$1"; _load_chapter "$ch"
    if [[ "${CH_NEEDS_RESCUE:-0}" = 1 ]]; then
        local fix; fix="$(ch_solve_in_rescue)"
        echo "▶ Applico la soluzione di riferimento dalla soccorso…"
        lab_rescue --run "$fix"
    else
        echo "Questo capitolo non ha una soluzione da soccorso."; return 1
    fi
}

cmd_hint()  { local ch="$1"; _load_chapter "$ch"; ch_hint "${2:-1}"; }
cmd_reset() { local ch="$1"; echo "Riparto da capo…"; cmd_start "$ch"; }
cmd_stop()  { lab_stop_target; echo "Macchine spente."; }

case "${1:-}" in
    list)   cmd_list ;;
    start)  cmd_start "${2:?uso: qlab-lab start <capitolo>}" ;;
    rescue) shift; lab_rescue "$@" ;;
    check)  cmd_check "${2:?uso: qlab-lab check <capitolo>}" ;;
    solve)  cmd_solve "${2:?uso: qlab-lab solve <capitolo>}" ;;
    hint)   cmd_hint "${2:?uso: qlab-lab hint <capitolo> [n]}" "${3:-1}" ;;
    reset)  cmd_reset "${2:?uso: qlab-lab reset <capitolo>}" ;;
    stop)   cmd_stop ;;
    *) echo "uso: qlab-lab {list|start|rescue|check|solve|hint|reset|stop} [capitolo]"; exit 1 ;;
esac
