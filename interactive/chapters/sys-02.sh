#!/usr/bin/env bash
# sys-02 — Rescue a machine that won't boot (interactive chapter definition).
#
# One source of truth, split into the three moves a real lab needs and the
# monolithic test never did: SEED the fault (hidden), CHECK the invariant
# (no fixing), SOLVE it (reference, for `lab solve`/CI). The seed value is a
# random bad UUID, written HOST-SIDE (never inside the VM): the student — even
# from the rescue system — cannot read the answer, only discover it.

CH_TITLE="Recupera una macchina che non parte"
CH_NEEDS_RESCUE=1   # this chapter's machine boots broken; the student needs `lab rescue`

ch_brief() {
cat <<'EOF'
  La macchina NON si avvia più: una riga in /etc/fstab punta a un filesystem
  che non esiste, e il boot si ferma in emergency. Non puoi entrare via SSH —
  non c'è più nessun SSH da raggiungere.

  Recuperala:
    1.  qlab-lab rescue            → una macchina di soccorso, col disco rotto su /dev/vdb
    2.  dentro: monta /dev/vdb1, correggi /etc/fstab, smonta, spegni (poweroff)
    3.  qlab-lab check sys-02      → riaccende la macchina da sola e controlla

  La verifica non guarda un file: riavvia la VM da spenta e pretende che arrivi
  al login — e che la CAUSA sia sparita, non nascosta con un trucco.
EOF
}

# ch_seed <ssh_cmd>  — run against the CLEAN, booted target; inject the fault and
# record the hidden value host-side. Then the caller reboots into breakage.
ch_seed() {
    local ssh="$1"
    # A random, definitely-absent UUID. Written host-side (see SEED_FILE), so the
    # student cannot read the answer — only discover it in the rescue.
    local bad; bad="deadbeef-$(printf '%04x' $((RANDOM%65536)))-$(printf '%04x' $((RANDOM%65536)))-dead-$(printf '%012x' $((RANDOM*RANDOM)))"
    $ssh "echo 'UUID=$bad /srv/rotto ext4 defaults 0 2' | sudo tee -a /etc/fstab >/dev/null" >/dev/null 2>&1 || true
    printf '%s' "$bad" > "$SEED_FILE"
}

# ch_check  — boot the target standalone and read the verdict. No SSH needed to
# reach emergency; we read the serial oracle and then SSH once it's up.
# Returns 0 = passed. Prints human feedback.
ch_check() {
    local bad; bad="$(cat "$SEED_FILE" 2>/dev/null)"
    lab_boot_target_fresh   # boots $TARGET_OVERLAY under the bench, leaves it running
    if ! banco_boot_clean lab-target 200; then
        # still not booting: is it stuck at emergency?
        if banco_serial_has lab-target "$BANCO_EMERGENCY_RE"; then
            echo "  ✗ La macchina si ferma ancora in emergency: il boot non è riparato."
        else
            echo "  ✗ La macchina non è arrivata al login entro il tempo atteso."
        fi
        return 1
    fi
    local ssh; ssh="$(banco_ssh "$SSH_KEY" "$LAB_PORT")"
    banco_wait_ssh "$ssh" 60 || true
    echo "  ✓ La macchina è tornata ad avviarsi e risponde."
    if [[ -n "$bad" ]] && $ssh "grep -q '$bad' /etc/fstab" >/dev/null 2>&1; then
        echo "  ✗ Ma la riga rotta è ancora in /etc/fstab: hai aggirato il sintomo, non tolto la causa."
        return 1
    fi
    echo "  ✓ E la causa è sparita: la riga rotta non è più in /etc/fstab."
    return 0
}

# ch_solve  — the reference fix, applied from a rescue (used by `lab solve` and CI).
# Runs INSIDE the rescue system, where the target root is /dev/vdb1.
ch_solve_in_rescue() {
    local bad; bad="$(cat "$SEED_FILE" 2>/dev/null)"
    echo "sudo mount /dev/vdb1 /mnt && sudo sed -i '/${bad}/d' /mnt/etc/fstab && sudo umount /mnt && echo FIXED"
}

ch_hint() {
    case "${1:-1}" in
        1) echo "  Il boot si ferma perché systemd non riesce a montare tutto ciò che c'è in fstab." ;;
        2) echo "  Dalla soccorso: 'sudo mount /dev/vdb1 /mnt', poi apri /mnt/etc/fstab e togli la riga che punta a /srv/rotto." ;;
        *) echo "  sudo mount /dev/vdb1 /mnt && sudo sed -i '\\|/srv/rotto|d' /mnt/etc/fstab && sudo umount /mnt, poi poweroff." ;;
    esac
}
