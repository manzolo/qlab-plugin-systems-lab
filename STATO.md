# STATO — systems-lab

**v0.2 — MVP verde: sys-01, sys-02, sys-04 passano end-to-end su VM vere.**
Nato il 2026-08-25 come repo separato (decisione di Andrea), fratello di `cyber-lab`.
Piano di famiglia: `GemelloDigitale/20_Progetti/linuxlab-percorsi.md`.

## Cosa c'è

- **`plugin.conf`, `install.sh`, `run.sh`** — boot del target (Ubuntu cloud image via qlab,
  disco dati extra su `/dev/vdb`), convenzioni identiche agli altri plugin.
- **`lib/banco.sh`** — il banco, cioè le quattro capacità misurate e provate a mano il
  2026-08-25 (vedi `linuxlab-percorsi.md`, "Esiti delle misure"):
  1. oracolo seriale (`banco_serial_has` / `banco_wait_serial`, verdetti emergency vs login);
  2. power-cycle dal guest (`banco_reboot_guest`) + boot del target sotto il banco
     (`banco_boot_target`), perché `qlab run` **ricrea l'overlay** e cancellerebbe la riparazione;
  3. ispezione/riparazione offline con VM di soccorso (`banco_rescue_run`);
  4. prova di proprietà prima di toccare (monta il disco rw dalla soccorso, non da root host).
- **`lab/rescue.sh`** — la versione interattiva della soccorso, per il percorso umano di sys-02.
- **`tests/test_02_*`** — l'invariante sys-02 end-to-end: baseline pulita → guasto fstab →
  power-cycle → emergency in seriale + SSH giù → riparazione dalla soccorso → boot pulito →
  la **causa** è sparita, non solo il sintomo.
- **`guide.md`, `README.md`** — la promessa e il passo-passo.

## Cosa è provato, e come — MVP verde su VM vere il 2026-08-25

Non «il codice sembra giusto»: ogni capitolo semina un cambiamento, **power-cycla una macchina
vera** e legge il verdetto dal boot. Verde riprodotto — *un verde non riprodotto non vale*.

- ✅ **sys-01 «come si avvia davvero Linux» — 8/8.** Aggiunge un parametro kernel via drop-in
  `grub.d`, riavvia, e il parametro è in **`/proc/cmdline`** dopo un boot **nuovo** (boot_id
  cambiato, non la sessione vecchia), confermato anche dal boot log.
- ✅ **sys-02 «recupera una macchina che non parte» — 10/10.** Guasto fstab → il boot si ferma
  in emergency (seriale) e SSH cade → riparazione dalla VM di soccorso → lo **stesso** overlay
  riavviato torna al `login:` → la **causa** è sparita, non solo il sintomo.
- ✅ **sys-04 «partizioni su dischi virtuali» — 11/11.** GPT reale su `/dev/vdb`, filesystem,
  mount **per UUID** in fstab (con `nofail`), riavvio → il mount **torna da solo** ed è il
  device con quell'UUID (identità, non lettera).
- **Sintassi** di tutti gli script: OK (`bash -n`).

## Bug trovati solo bootando (la lezione del progetto, dal vivo)

Il collaudo ha ripagato a ogni capitolo, trovando difetti che nessuna rilettura del codice
mostrava — che è *esattamente* ciò che questo lab insegna:

1. **La VM di soccorso bootava senza cloud-init** → niente utente `labuser`, niente chiave,
   `sshd` non partiva. Mancava la cidata ISO. → `banco_rescue_run` e `rescue.sh` la passano.
2. **Un `runcmd` con `\$(findmnt ...)` era un escape YAML invalido**: cloud-init scartava
   **tutto** lo user-data del target → SSH rifiutato, mentre l'hostname (dal meta-data) faceva
   sembrare la macchina a posto. → `runcmd` rimosso.
3. **La corsa del reboot** (sys-01): dopo `reboot`, sshd resta su qualche secondo e un check
   si riaggancia alla **sessione vecchia**, leggendo lo stato pre-reboot. → `banco_reboot_wait_newboot`
   aspetta il cambio di **`boot_id`**: legge solo quando siamo provabilmente su un boot nuovo.
4. **Il drop-in `grub.d` che vince** (sys-01): la cloud image ha
   `/etc/default/grub.d/50-cloudimg-settings.cfg` che **sovrascrive** `GRUB_CMDLINE_LINUX_DEFAULT`
   *dopo* `/etc/default/grub` — editare il file principale non ha effetto (il cmdline attivo non
   porta nemmeno il «quiet splash» del file principale). → il parametro va messo in un drop-in
   `99-lab.cfg` che gira per ultimo. È diventato un **punto didattico di sys-01**.
5. **`dmesg` ristretto** (sys-01): `kernel.dmesg_restrict` → serve `sudo` per leggere la riga
   `Command line` dal log del kernel.

## Trappole già pagate (dalle misure, da non ripagare)

- `qlab run` fa `rm -f overlay`: per un power-cycle che conserva la riparazione serve il boot
  sotto il banco, non un secondo `qlab run`. → risolto in `banco_boot_target`. È verde.
- **Collisione PARTUUID**: soccorso e target derivano dalla stessa base → stessi PARTUUID;
  ancorare l'identità del disco (label), non l'ordine di scansione — materia di sys-04.
- La seriale qlab è `file:` + `-monitor none`: log sì, console interattiva no. In emergency
  mode non c'è SSH → la soccorso è l'unica via, ed è la lezione.

## Non ancora fatto (vedi BACKLOG)

- ⏳ **Integrazione con `qlab test`**: la guardia di `qlab test` pretende una VM già in
  esecuzione, mentre questi test guidano i boot da soli e vogliono il target **fermo**. Per
  ora si lancia `bash .qlab/plugins/systems-lab/tests/run_all.sh` (dalla copia installata, dove
  `lab/` ha il disco provisionato). Adattare la guardia o il runner è il prossimo passo.
