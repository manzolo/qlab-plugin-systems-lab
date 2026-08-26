#!/usr/bin/env bash
# sys-07 — Diagnose the bottleneck (interactive, in-place: the machine stays up).
#
# The seed picks a fault CLASS at random (cpu or disk) and hides it host-side.
# The student cannot assume which — they must OBSERVE, then cure. The check reads
# the LIVE machine: healthy = no process devouring the CPU and no filesystem at
# 100%. No reboot here; the fault is runtime, so the machine must stay running
# between `start` and `check`.

CH_TITLE="Trova il collo di bottiglia (macchina viva)"
# in-place: no rescue; the student fixes from inside via `qlab-lab shell`.

ch_brief() {
cat <<'EOF'
  La macchina è LENTA. Ma «lenta» non è una diagnosi: può essere la CPU al
  100% o un filesystem pieno che blocca le scritture — e cambia a ogni mondo.

    1.  qlab-lab shell            → entra nella macchina
    2.  OSSERVA prima di curare: uptime / ps (CPU), df -h (disco)
    3.  cura SOLO ciò che è al limite (killa il processo giusto, libera il
        mount giusto), poi esci
    4.  qlab-lab check sys-07     → controlla che sia tornata sana

  La verifica guarda il sistema vivo: nessun processo che divora la CPU,
  nessun mount al 100%.
EOF
}

ch_seed() {
    local ssh="$1"
    # cleanup a previous world
    $ssh "sudo pkill -9 -f /usr/local/bin/hog 2>/dev/null; sudo rm -f /usr/local/bin/hog*; for m in \$(mount 2>/dev/null | awk '/\/mnt\/pieno/{print \$3}'); do sudo umount \$m 2>/dev/null; done; sudo rm -f /tmp/lab-full.img; sudo rm -rf /mnt/pieno" >/dev/null 2>&1 || true
    local cls; if [ $((RANDOM % 2)) -eq 0 ]; then cls=cpu; else cls=disco; fi
    cls="${LAB_FORCE_CLASS:-$cls}"   # validazione: forza la classe; a runtime è casuale
    if [ "$cls" = cpu ]; then
        local n="hog$RANDOM"
        $ssh "printf '#!/bin/sh\nwhile :; do :; done\n' | sudo tee /usr/local/bin/$n >/dev/null && sudo chmod +x /usr/local/bin/$n && sudo setsid nice -n 19 /usr/local/bin/$n >/dev/null 2>&1 < /dev/null &" >/dev/null 2>&1 || true
    else
        $ssh "sudo mkdir -p /mnt/pieno && sudo dd if=/dev/zero of=/tmp/lab-full.img bs=1M count=20 2>/dev/null && sudo mkfs.ext4 -qF /tmp/lab-full.img >/dev/null 2>&1 && sudo mount -o loop /tmp/lab-full.img /mnt/pieno && sudo dd if=/dev/zero of=/mnt/pieno/riempi bs=1M >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    fi
    printf '%s' "$cls" > "$SEED_FILE"
    sleep 3
}

ch_check() {
    local ssh; ssh="$(banco_ssh "$SSH_KEY" "$LAB_PORT")"
    banco_wait_ssh "$ssh" 60 || { echo "  ✗ La macchina non risponde."; return 1; }
    local topcpu full
    topcpu=$($ssh "ps -eo pcpu= --sort=-pcpu 2>/dev/null | head -1 | cut -d. -f1" 2>/dev/null | tr -dc '0-9')
    full=$($ssh "df -P 2>/dev/null | awk '\$5==\"100%\"{print \$6}' | grep -vx / | head -1" 2>/dev/null | tr -d '\r\n ')
    echo "  osservato: CPU top ${topcpu:-0}%, mount pieno: ${full:-nessuno}"
    if { [ -z "$topcpu" ] || [ "$topcpu" -lt 50 ]; } && [ -z "$full" ]; then
        echo "  ✓ Sistema sano: nessun processo divora la CPU, nessun filesystem al 100%."
        return 0
    fi
    echo "  ✗ C'è ancora un collo di bottiglia da curare."
    return 1
}

ch_solve_inplace() {
    local ssh="$1"; local cls; cls="$(cat "$SEED_FILE" 2>/dev/null)"
    if [ "$cls" = cpu ]; then
        $ssh "sudo pkill -9 -f /usr/local/bin/hog" >/dev/null 2>&1 || true
    else
        # il più grosso FILE (non la directory-totale): du elenca anche il mount
        # stesso in cima, che non è un file — va saltato (stesso baco di test_07).
        $ssh "mp=\$(df -P | awk '\$5==\"100%\"{print \$6}' | grep -vx / | head -1); [ -n \"\$mp\" ] && { f=\$(sudo du -a \"\$mp\" 2>/dev/null | sort -rn | while read -r s p; do [ -f \"\$p\" ] && { echo \"\$p\"; break; }; done); [ -n \"\$f\" ] && sudo rm -f \"\$f\"; }" >/dev/null 2>&1 || true
    fi
    sleep 2; echo "CURATA ($cls)"
}

ch_hint() {
    case "${1:-1}" in
        1) echo "  Guarda le risorse SEPARATE: 'uptime' per il carico CPU, 'df -h' per lo spazio." ;;
        2) echo "  CPU al 100%? 'ps aux --sort=-%cpu | head' e killa il colpevole. Disco al 100%? 'df -h' trova il mount, 'du -ah MOUNT | sort -n | tail' il file, poi rm." ;;
        *) echo "  cpu: sudo pkill -9 -f /usr/local/bin/hog · disco: rm del file grosso nel mount a 100%." ;;
    esac
}
