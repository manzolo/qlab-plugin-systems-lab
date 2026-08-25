# BACKLOG — systems-lab

L'invariante di ogni esercizio va scritto **prima** del codice: è la parte difficile e la
sola che distingue un corso da un poligono (lezione di SshLab/CyberLab).

## Subito (chiude la v0.1 davvero)

- [x] ✅ **sys-02 verde end-to-end su VM vere** — 10/10 il 2026-08-25 (vedi STATO). Fatto.
- [ ] **Integrazione con `qlab test`.** Oggi la guardia di `qlab test` pretende una VM già in
      esecuzione, mentre questi test guidano i boot da soli e vogliono il target **fermo**.
      Per ora: `bash .qlab/plugins/systems-lab/tests/run_all.sh` dalla copia installata. Da
      decidere: la guardia salta il check per systems-lab, o il runner fa `qlab run`+`stop`.
- [ ] **Ordine dei dischi nella soccorso.** `test_02` oggi riesce perché `banco_rescue_run`
      attacca solo l'overlay (disco rotto = `/dev/vdb`). Quando la soccorso monterà anche il
      disco dati, ancorare per label/serial, non per lettera — trappola PARTUUID applicata.

## MVP — FATTO

- [x] ✅ **sys-01 «come si avvia davvero Linux» — 8/8 verde.** Parametro kernel via drop-in
      `grub.d`, presente in `/proc/cmdline` dopo un boot nuovo. Insegna anche la trappola del
      drop-in cloud-image che sovrascrive `/etc/default/grub`.
- [x] ✅ **sys-02 «recupera una macchina che non parte» — 10/10 verde.**
- [x] ✅ **sys-04 «partizioni su dischi virtuali» — 11/11 verde.** GPT + mount per UUID che
      sopravvive al reboot, per identità e non per lettera.

## Capstone MVP

- [ ] sys-08 ridotto: fstab rotto **+** modulo/mount concatenati; il check parte da VM spenta.
      Riusa `banco_boot_target` + oracolo seriale + `banco_rescue_run`, tutti già verdi.

## Banco — capacità ancora da irrobustire

- [ ] **Guastatore col seme**: oggi `test_02` inietta un guasto fisso. Serve un seme che
      parametrizzi *quale* riga/UUID/parametro rompere, e un check che pretenda il valore del
      seme (l'anti-trucco di famiglia portato sul boot).
- [ ] **Timeout onesti sull'oracolo**: il silenzio non è una prova. `banco_wait_serial` già
      distingue emergency da login; verificare i tempi sul runner più lento (CI, se ci sarà).
- [ ] **CI**: valutare un workflow che faccia girare `qlab test` in un runner con KVM
      (probabilmente self-hosted — GitHub Actions non dà `/dev/kvm` di default). Se non c'è KVM,
      il boot in emulazione pura è lento ma possibile: misurare.

## Più avanti (Systems completo)

- [ ] sys-03 (kernel/moduli/sysctl persistente), sys-05 (LUKS: dati illeggibili a volume
      chiuso, verificato dalla soccorso), sys-06 (rete persistente con systemd-networkd),
      sys-07 (diagnostica: classificare prima di curare), sys-08 pieno.

## Superficie/vetrina (quando l'MVP è online)

- [ ] Card "Linux Systems" già presente nel sommario e nei README di LinuxLab (fatto il
      2026-08-25, Piano A): quando l'MVP gira, aggiungere il link e togliere "in costruzione".
- [ ] Riga nel README di qlab (tabella plugin) e nella vetrina www.manzolo.it, come cyber-lab.
