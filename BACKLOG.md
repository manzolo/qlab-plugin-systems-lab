# BACKLOG — systems-lab

L'invariante di ogni esercizio va scritto **prima** del codice: è la parte difficile e la
sola che distingue un corso da un poligono (lezione di SshLab/CyberLab).

## Subito (chiude la v0.1 davvero)

- [x] ✅ **sys-02 verde end-to-end su VM vere** — 10/10 il 2026-08-25 (vedi STATO). Fatto.
- [ ] **Integrazione con `qlab test`.** Oggi la guardia di `qlab test` pretende una VM già in
      esecuzione, mentre questi test guidano i boot da soli e vogliono il target **fermo**.
      Per ora: `bash .qlab/plugins/systems-lab/tests/run_all.sh` dalla copia installata. Da
      decidere: la guardia salta il check per systems-lab, o il runner fa `qlab run`+`stop`.
- [x] ✅ **Ordine dei dischi nella soccorso — risolto per costruzione (2026-08-25).** La
      trappola PARTUUID ha morso davvero (la soccorso ha montato la root del target, vedi
      STATO bug 13): ora la soccorso **boota da sola** e i dischi del paziente arrivano
      **dopo, via hotplug QMP** — target sempre `/dev/vdb`, disco dati sempre `/dev/vdc`,
      per ordine di aggancio e senza ambiguità di root.

## MVP — FATTO

- [x] ✅ **sys-01 «come si avvia davvero Linux» — 8/8 verde.** Parametro kernel via drop-in
      `grub.d`, presente in `/proc/cmdline` dopo un boot nuovo. Insegna anche la trappola del
      drop-in cloud-image che sovrascrive `/etc/default/grub`.
- [x] ✅ **sys-02 «recupera una macchina che non parte» — 10/10 verde.**
- [x] ✅ **sys-04 «partizioni su dischi virtuali» — 11/11 verde.** GPT + mount per UUID che
      sopravvive al reboot, per identità e non per lettera.

## Capstone MVP — FATTO

- [x] ✅ **sys-08 ridotto — 16/16 verde.** Guasti concatenati (fstab che blocca il boot +
      servizio disabilitato che emerge solo dopo la riparazione); il check parte da una VM
      **davvero spenta** e finisce con un power-cycle in cui il battito su `/run` (tmpfs)
      prova che il servizio ha girato sul boot fresco.

## Banco — capacità ancora da irrobustire

- [ ] **Teardown anche su abort**: un test che muore a metà lascia l'overlay sporco (es. fstab
      rotto seminato e mai riparato) e avvelena i test successivi — successo il 2026-08-25
      quando il timeout della soccorso ha abortito sys-02. Mitigato (chiamate alla soccorso
      guardate, timeout 300s); la cura vera è un trap per-test che ripristina i semi noti.

- [ ] **Guastatore col seme**: oggi `test_02` inietta un guasto fisso. Serve un seme che
      parametrizzi *quale* riga/UUID/parametro rompere, e un check che pretenda il valore del
      seme (l'anti-trucco di famiglia portato sul boot).
- [ ] **Timeout onesti sull'oracolo**: il silenzio non è una prova. `banco_wait_serial` già
      distingue emergency da login; verificare i tempi sul runner più lento (CI, se ci sarà).
- [ ] **CI**: valutare un workflow che faccia girare `qlab test` in un runner con KVM
      (probabilmente self-hosted — GitHub Actions non dà `/dev/kvm` di default). Se non c'è KVM,
      il boot in emulazione pura è lento ma possibile: misurare.

## Più avanti (Systems completo)

- [x] ✅ **sys-03 (kernel/moduli/sysctl persistente) — 13/13 verde.** Sysctl dal seme vivo
      dopo power-cycle; giro moduli con scoperta dinamica (il kernel -kvm ha i .ko).
- [x] ✅ **sys-05 (LUKS) — 14/14 verde.** Attaccante (soccorso) vs proprietario (passphrase);
      controllo positivo sulla sonda; ha imposto il passaggio all'immagine standard.
- [x] ✅ **sys-06 (rete persistente) — 12/12 verde alla prima uscita completa.** Atto 1: lo
      stato di ip(8) evapora; atto 2: netplan/networkd torna da solo (indirizzo, route, DNS
      misurati separatamente). Seconda NIC su LAN isolata, match per MAC.
- [x] ✅ **sys-07 (diagnostica) — 10/10 verde al primo colpo.** Tre classi, classificazione
      dalle misure, cura guidata dalle misure, classificatore muto su macchina sana.
- [x] ✅ **sys-08 pieno — 26/26 verde.** Quattro guasti concatenati (boot/storage/servizio/
      rete), soccorso chirurgica, diagnosi da vivi, power-cycle finale con ogni strato che
      torna da solo. **Il percorso non ha più capitoli mancanti.**

## Superficie/vetrina (quando l'MVP è online)

- [ ] Card "Linux Systems" già presente nel sommario e nei README di LinuxLab (fatto il
      2026-08-25, Piano A): quando l'MVP gira, aggiungere il link e togliere "in costruzione".
- [ ] Riga nel README di qlab (tabella plugin) e nella vetrina www.manzolo.it, come cyber-lab.
