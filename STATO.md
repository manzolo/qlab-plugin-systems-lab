# STATO — systems-lab

**v0.1 — scaffold del percorso Linux Systems, con l'invariante di sys-02 codificato.**
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

## Cosa è provato, e come

- ✅ **sys-02 è VERDE end-to-end su VM vere — 10/10 asserzioni, il 2026-08-25.** Non «il
  codice sembra giusto»: `tests/run_all.sh` dalla copia installata ha eseguito il giro intero
  — baseline pulita → guasto fstab → **il boot si ferma in emergency (letto dalla seriale) e
  SSH cade** → riparazione dalla VM di soccorso → lo **stesso** overlay riavviato torna al
  `login:` → la **causa** è sparita, non solo il sintomo. Verde riprodotto: *un verde non
  riprodotto non vale*, e questo lo è.
- **Sintassi** di tutti gli script: OK (`bash -n`).

## Due bug trovati solo bootando (la lezione del progetto, dal vivo)

Il collaudo ha ripagato subito, trovando due difetti che nessuna rilettura del codice mostrava:

1. **La VM di soccorso bootava senza cloud-init** → niente utente `labuser`, niente chiave,
   `sshd` non partiva («Failed to start OpenBSD Secure Shell server»). Mancava la cidata ISO
   alla soccorso. → `banco_rescue_run` e `rescue.sh` ora la passano.
2. **Un `runcmd` con `\$(findmnt ...)` era un escape YAML invalido** (`found unknown escape
   character '$'`): cloud-init scartava **tutto** lo user-data del target → niente chiave,
   SSH rifiutato. L'hostname arrivava dal **meta-data**, ecco perché sembrava provisionato a
   metà. La sintassi shell era «perfetta»; solo il boot ha rivelato che non lo era — che è
   esattamente ciò che questo lab insegna. → `runcmd` rimosso (la label del disco è sys-04).

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
