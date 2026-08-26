# STATO — systems-lab

**v0.7 — il percorso è completo, capstone pieno incluso: tutti e otto i capitoli verdi
end-to-end su VM vere.** Dalla v0.5 il target usa l'**immagine cloud standard** (kernel
`-virtual`), non la minimal: il suo `linux-kvm` non ha dm-crypt (vedi bug 8).
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
- ✅ **sys-03 «kernel, /proc, /sys e sysctl» — 13/13, verde al primo colpo.** Valore
  `kernel.pid_max` dal seme: vivo a runtime (`sysctl -w`), persistente (`/etc/sysctl.d`),
  **ancora vivo dopo un power-cycle vero**; mostrata l'equivalenza `sysctl` ↔ `/proc/sys`.
  E il giro moduli regge: il kernel `-kvm` **ha** moduli caricabili (trovato `affs`
  dinamicamente, caricato, visto in `lsmod` e `/sys/module`, `modinfo`, scaricato) — il
  dubbio "kernel minimale senza .ko" era infondato, misurato e chiuso.
- ✅ **sys-05 «LUKS e storage stratificato» — 14/14.** La scena intera dal punto di vista
  giusto, **la soccorso = l'attaccante col disco in mano**: il file in chiaro `chmod 600` sul
  disco di root **si legge** (i permessi non sono una difesa lì); la partizione si dichiara
  `crypto_LUKS`; il segreto **non compare da nessuna parte** nei byte grezzi del disco dati —
  e la sonda **prima dimostra di saper trovare il plaintext** sul disco in chiaro (lo zero ha
  due letture, si separano provando il filtro). Poi il lato del proprietario: passphrase →
  `open --key-file -` → il segreto è intatto dopo close + power-cycle.
- ✅ **sys-06 «rete persistente» — 12/12, verde alla prima uscita completa.** Seconda NIC su
  LAN isolata (match per **MAC**, identità e non nome), e i due atti che *sono* la lezione:
  l'indirizzo messo con `ip addr add` **evapora** al power-cycle; lo stesso indirizzo + route
  statica + DNS via **netplan/systemd-networkd** tornano da soli — e si misurano
  **separatamente** dal sistema vivo (`ip addr`, `ip route`, `resolvectl`), mai dal file.
- ✅ **sys-07 «diagnostica e prestazioni» — 10/10, verde al primo colpo.** Tre classi di
  guasto (CPU-bound, memoria esaurita, disco pieno) in ordine ruotato dal seme: il check
  pretende **prima la classificazione giusta dalle misure vive** (mai dal seme), poi una cura
  **guidata dalle misure** (il pid più affamato, il file più grosso — mai "il nome che
  conosco"), poi di nuovo «sano» misurato. E il classificatore è provato nei due sensi:
  su macchina sana deve tacere.
- ✅ **sys-08 capstone PIENO «recupera una macchina che non parte» — 26/26.** **Quattro**
  guasti concatenati su tutti gli strati del percorso: il blocco di boot (fstab, no nofail)
  **nasconde** un mount dati rotto (UUID sbagliato ma nofail), da cui **dipende** un servizio
  (`RequiresMountsFor`) che è pure disabilitato, mentre la rete persistente porta l'indirizzo
  sbagliato. Il check parte da macchina **davvero spenta**; la soccorso ripara **solo** il
  boot (il resto si diagnostica da vivi, misurando: `findmnt`, `systemctl`, `ip addr`); cure a
  strati — storage con l'UUID **riletto dal disco**, servizio, rete — e il power-cycle finale
  prova che ogni strato torna da solo. Il battito è il **token letto dal mount vero** copiato
  in `/run` (tmpfs): un file solo che prova boot+storage+servizio su un boot fresco.
  Fuori perimetro, dichiarati: il guasto "modulo necessario" (niente su questa VM rende un
  modulo portante; la lezione moduli vive in sys-03) e il firewall (servirebbe un peer esterno).
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
6. **Non si può maskare un'unità che vive in `/etc/systemd/system`** (sys-08): `mask` deve
   creare il symlink a `/dev/null` proprio in quel path, che è occupato dal file vero →
   `systemctl` rifiuta con rc≠0, e sotto `set -e` il test moriva **in silenzio**. Doppia cura:
   il guasto B è diventato `disable --now` (realistico e funzionante), e ogni semina ora è
   **auto-diagnostica** — una riga per guasto con `|| true`, seguita da un assert che dice
   *quale* semina non ha attecchito.
7. **`cryptsetup open` non prende la chiave come posizionale** (sys-05): il `-` finale vale
   per `luksFormat`; `open` vuole `--key-file -`. Sbagliarlo = il volume non si apre mai, e
   il primo run aveva anche un **verde vacuo**: «il segreto non è nei byte grezzi» passava
   perché il segreto non era mai stato scritto. Cura doppia: stderr di cryptsetup catturato
   e stampato (l'errore si nomina da solo), e la sonda ha un **controllo positivo** — deve
   prima trovare il plaintext sul disco in chiaro, solo allora il suo zero vale.
8. **Il kernel `linux-kvm` della minimal non ha dm-crypt** (sys-05): `modprobe dm_crypt` →
   *not found*, dmesg dice `crypt: unknown target type`, e niente xts (`cryptsetup benchmark`
   boccia tutto). Nessun pacchetto lo aggiunge su quel flavor: la cura è l'**immagine cloud
   standard** (kernel `-virtual`), dichiarata nel run.sh — e l'intera suite è stata rifatta
   sul kernel nuovo, perché la base era cambiata sotto tutti i capitoli.
9. **Il recordfail di GRUB blocca per sempre una macchina headless dopo un taglio di
   corrente** (suite sull'immagine standard): dopo uno shutdown non pulito GRUB mette
   `timeout=-1` e aspetta una tastiera che non esiste — ogni boot successivo a un kill del
   banco si impiantava al menu. Cura nel provisioning: `GRUB_RECORDFAIL_TIMEOUT=3` in un
   drop-in `grub.d`. È materia da capitolo: un server vero non deve piantarsi al GRUB dopo
   un black-out. (La minimal non mostrava il problema.)
10. **SSH risponde secondi PRIMA che getty stampi `login:` sulla seriale** (sys-02 sul kernel
    -virtual): un check che fotografa il log seriale subito dopo il wait su SSH corre contro
    getty e perde. Il verdetto seriale si **aspetta**, non si fotografa.
11. **«Esiste su disco» non è «si carica»** (sys-03 sul kernel generic): il primo `.ko`
    trovato era `ubuntu-host`, che in QEMU rifiuta di caricarsi. La scelta del modulo ora
    **prova a caricare** i candidati finché uno va (prima `dummy`, che è software puro).
    E una lezione di sessione, pagata due volte: **le sonde inline girano in zsh, dove
    `$cmd` non fa word-splitting** — una macchina viva dichiarata morta dal client rotto.
    Le sonde si scrivono in file bash, sempre.
12. **Una soccorso che installa pacchetti è una soccorso inaffidabile**: usava la cidata del
    target (apt di 4 pacchetti via SLIRP + update-grub al primo boot) e una volta ha sforato
    il timeout del banco, abortendo sys-02 e avvelenando i test a valle con l'fstab mai
    riparato. Doppia cura: **cidata minimale dedicata** (utente+chiave e basta — una soccorso
    dev'essere noiosa e rapida) e il banco che al fallimento **conserva il log seriale su
    stderr** invece di cancellare le prove col tmpdir.
13. **La trappola PARTUUID ha morso davvero** (annunciata dal piano il giorno stesso):
    soccorso e target derivano dalla stessa base → root gemelle → con entrambi i dischi
    presenti al boot il kernel sceglie la root per **ordine di scansione**, e una volta ha
    montato come root della soccorso **il disco avvelenato del target**, finendo lei stessa
    in emergency. Cura definitiva: **la soccorso boota da sola e il paziente arriva dopo** —
    hotplug del disco via QMP (`drive_add`+`device_add`) a macchina su. Chiude anche la voce
    "ordine dei dischi nella soccorso" del BACKLOG.
14. **Un QEMU morente tiene ancora il write-lock sul disco**: il percorso di fallimento della
    soccorso usava un `kill` secco senza attesa, e il boot successivo trovava
    `Failed to get "write" lock`. Ogni uscita ora passa da `banco_stop_pid`
    (attesa + SIGKILL + pidfile rimosso).

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

## Fatto il 2026-08-26 — modalità interattiva `qlab-lab`, pilota sys-02

Nasce la strada «renderli usabili da una persona». `interactive/lab.sh` +
`interactive/chapters/<ch>.sh`: il monolite `qlab test` (semina+ripara+verifica
in un colpo) è spezzato in **seed / check / solve**, con lo studente in mezzo.
Il seme è nascosto **host-side** (`lab/.lab-seed-<ch>`, fuori dalla VM): dalla
soccorso non lo leggi, lo scopri. Riusa il banco (boot persistente, oracolo
seriale, soccorso con hotplug QMP).

**Pilota sys-02 verde end-to-end** (simulazione dello studente il 2026-08-26):
`start` semina un UUID rotto casuale e manda la macchina in emergency; `check`
subito dopo **fallisce** giustamente; `solve` (dalla soccorso) ripara; `check`
**passa** perché la VM da spenta arriva al login **e** quella riga rotta
specifica non è più in fstab (mascherare non basta). Anti-trucco reale.

Comandi: `list | start <ch> | rescue | check <ch> | hint <ch> [n] | solve <ch>
| reset <ch> | stop`. Resta da portare la ricetta sugli altri capitoli (uno
`chapters/<ch>.sh` ciascuno, riusando i seed/check dei test).
