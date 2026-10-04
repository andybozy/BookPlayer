# BookPlayer personale con Audiobookshelf

Questo branch aggiunge una modalità autonoma iOS/watchOS che usa direttamente il proprio Audiobookshelf. Non richiede un backend BookPlayer, acquisti Pro, RevenueCat, Sign in with Apple, Sentry o sincronizzazione tramite il cloud gestito di BookPlayer. Non assegna un abbonamento Pro e non accede a servizi a pagamento dell'upstream.

**Stato:** implementazione dei sorgenti e configurazione Xcode preparate; build Apple, firma, esecuzione sui dispositivi e submit deliberatamente non eseguiti. Le verifiche Linux di sintassi/progetto e le prove contro ABS reale sono distinte dalla compilazione con SDK Apple. Non distribuire questa modifica prima delle verifiche riportate sotto.

## Server e librerie

Endpoint predefinito: `https://audiobooks.androshera.xyz`, ABS 2.37.1. Accedere con l'account ABS di ascolto (`andrea` nell'installazione iniziale), non con l'admin o con un account BookPlayer Cloud. Nessuna credenziale è inclusa nel repository o nel bundle. Un altro server HTTPS alla radice di un hostname è configurabile nella schermata di accesso.

Il server resta il riferimento di file, catalogo e progresso. Il client mostra tutte le librerie **book** autorizzate all'utente, con ricerca per titolo, autore, serie e narratore. Le directory vengono gestite da Chaptarr, non dal player. I download del telefono e del Watch sono copie locali per l'ascolto, separate dalla libreria del server.

Sono implementati:

- Lettura del catalogo paginato, metadata, copertine, durata e capitoli ABS.
- Streaming autenticato di file originali tramite richieste HTTP Range e `AVAssetResourceLoader`; nessun token nell'URL, nessun header AVURLAsset privato e nessuna transcodifica lato client.
- M4B e sequenze di tracce MP3, con tempi globali e selezione dei capitoli; gli altri codec dipendono dal supporto AVFoundation del dispositivo.
- Download URLSession in background, solo Wi-Fi, manifest persistente e verifica delle dimensioni per tutte le parti. La dicitura “Disponibile offline” appare solo a pacchetto completo. I retry riprendono le parti mancanti; non è garantito che un singolo file fallito riparta dall'ultimo byte.
- Play/pause, rewind 15 s, avanti 30 s, seek, velocità e sleep timer; Now Playing e comandi di sistema.
- Progresso salvato localmente ogni cinque secondi durante l'ascolto e alla pausa; invio ad ABS ogni circa trenta secondi, alla pausa, al ritorno in primo piano e al ripristino della rete.
- Distinzione fra rewind intenzionale e conflitto: confronto della revisione `lastUpdate` del server, non scelta della posizione più avanzata. Nei conflitti la libreria presenta le due posizioni e chiede quale mantenere.
- Credenziali in Keychain, storage separato per server/account e file protetti fino al primo sblocco. Logout impedito finché esistono aggiornamenti non sincronizzati o trasferimenti attivi. “Accedi nuovamente” rinnova le credenziali preservando la coda dello stesso account.
- Rilevamento di un'edizione offline incompatibile con tracce cambiate sul server. Una copia locale rimane utilizzabile senza rete; quando il cambiamento è riconoscibile online viene richiesto di riscaricarla.

Questa modalità ha una propria schermata libreria/player e un proprio manifest, senza migrazioni del CoreData upstream. Widget, import via share sheet/AirDrop, EPUB, playlist/collezioni, bookmark e statistiche delle sessioni di ascolto upstream **non sono integrati nella nuova modalità**. Il progresso ABS non equivale a registrare tutte le statistiche di una sessione ABS. I vecchi App Intents specifici del catalogo CoreData non costituiscono l'interfaccia di questa libreria.

## Apple Watch: entrambe le modalità

1. Installare la stessa build personale su iPhone e Watch abbinati.
2. Aprire l'app su entrambi. Sul telefono selezionare **Collega Apple Watch**. Il token passa al solo Watch abbinato con un messaggio esplicito WatchConnectivity e viene memorizzato nel Keychain del Watch; non è inserito nell'application context persistente. In alternativa accedere direttamente sul Watch.
3. La sezione **Controlla iPhone** invia play/pause e skip all'iPhone, quando raggiungibile. Titolo e stato viaggiano separatamente dalle credenziali.
4. Per ascolto autonomo aprire una libreria **sul Watch**, scaricare il libro e aspettare **Disponibile offline**. Il download sul telefono non implica che il file sia già sull'orologio.
5. Collegare le cuffie al Watch e avviare il libro dalla libreria del Watch. Dopo un primo sblocco e a download completo, iPhone e rete non sono necessari alla lettura dei file.
6. Il Watch conserva gli aggiornamenti offline e li riconcilia con ABS quando riacquista connettività e l'app viene eseguita. Non viene promesso un sync istantaneo con un'app sospesa dal sistema operativo.

URLSession e il sistema watchOS decidono quando possono completare i trasferimenti in background: per il primo download usare Wi-Fi, batteria adeguata e preferibilmente il caricatore. Prima di uscire verificare il segno “Disponibile offline”.

## Preparare la build sul Mac

Il branch usa `BuildConfiguration/SelfHosted.xcconfig` per Debug/Release. I vecchi `Debug.xcconfig`/`Release.xcconfig` privati non vengono sovrascritti. Il file pubblico include un override locale facoltativo, escluso da Git:

```bash
git switch selfhosted-abs
cp BuildConfiguration/SelfHosted.local.template.xcconfig BuildConfiguration/SelfHosted.local.xcconfig
open BookPlayer.xcodeproj
```

Nel file locale impostare il proprio `DEVELOPMENT_TEAM`; se desiderato cambiare `BP_BUNDLE_IDENTIFIER` (default `xyz.androshera.bookplayer`). Configurare nel proprio account Developer i bundle ID derivati dell'app, companion Watch ed estensioni, con App Group `group.<BP_BUNDLE_IDENTIFIER>.files`. Il gruppo è distinto da quello dell'app ufficiale: non importa né sovrascrive i suoi dati.

Gli entitlement della modalità personale non richiedono iCloud o Sign in with Apple. L'app iOS mantiene Siri; il Watch mantiene solo App Group. Xcode deve generare profili di provisioning del proprio team. Non inserire token/password ABS negli xcconfig.

Riferimento del progetto upstream: Xcode 26.4, deployment iOS 18/watchOS 10. Verificare le versioni effettivamente disponibili sul proprio Mac prima della build. Schema principale **BookPlayer**, companion **BookPlayerWatch**. Il progetto permette l'app iPad su Mac Apple Silicon; non introduce un'app macOS Intel o un target Catalyst.

Il supporto CarPlay contiene un browser essenziale del catalogo e Now Playing, ma l'interfaccia dell'app in CarPlay richiede l'approvazione Apple dell'entitlement audio. **L'entitlement CarPlay non è incluso per default**. La firma del codice non conferisce automaticamente quella capacità. I controlli di sistema Now Playing restano distinti dalla presenza dell'app nella griglia CarPlay.

Non eseguire le lane di distribuzione upstream assumendo che puntino al proprio account. App Store Connect, bundle ID, firma, eventuali capability CarPlay e submission vanno configurati nella fase di distribuzione personale. Licenza GPL e attribuzioni upstream sono preservate.

## Convalida Apple da eseguire prima della distribuzione

È disponibile il workflow **Self-hosted ABS validation (manual)**, soltanto `workflow_dispatch`. Il push di questo branch non lo avvia e non carica nulla su TestFlight/App Store. Anche l'eventuale workflow CI upstream su una futura PR verso `develop` può compilare: aprire quella PR quando si vuole iniziare la fase Apple.

Comandi equivalenti sul Mac, con un simulatore presente:

```bash
xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayer \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan 'Unit Tests' -only-testing:BookPlayerTests/SelfHostedABSTests \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project BookPlayer.xcodeproj -scheme BookPlayerWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Eseguire poi anche la suite upstream e prove su iPhone/Watch fisici. La sintassi Swift da sola non verifica disponibilità delle API, isolamento degli actor, signing o comportamento in background.

| Prova | Risultato richiesto |
|---|---|
| Avvio pulito iPhone + Watch | Schermata ABS, nessuna richiesta a BookPlayer Cloud, RevenueCat o Sentry |
| Account normale / account diverso | Solo librerie autorizzate; cache, token e progresso non si mescolano |
| M4B chaptered e MP3 in due parti | Seek e resume corretti, capitoli globali, cambio traccia senza salto di tempo |
| HTTPS remoto + Range | Streaming e seek su Wi-Fi/mobile, niente redirect con credenziali verso altri host |
| Download interrotto / spazio insufficiente | Nessun falso stato offline; errore leggibile e retry delle parti mancanti |
| Lock screen / cuffie scollegate / telefonata | Comandi corretti, pausa sicura, progresso conservato; niente ripresa indesiderata |
| Watch controlla telefono | Toggle/skip sul telefono, stato separato dall'ascolto locale del Watch |
| Watch senza iPhone e senza Internet | Libro interamente scaricato riproducibile con cuffie; posizione conservata dopo riavvio app |
| Offline su entrambi i dispositivi | Coda persistente; scelta esplicita se entrambi hanno modificato lo stesso libro |
| Riavvolgimento volontario | La posizione arretrata non viene sostituita da un criterio “più avanti vince” |
| Fine libro / riavvio dall'inizio | `isFinished` coerente e nuova lettura da zero esplicita |
| Token scaduto / credenziali rinnovate | Nuovo login dello stesso account preserva download e aggiornamenti pendenti |
| Server modifica/rimuove l'edizione | Nessuna ricombinazione silenziosa di audio vecchio e nuovo |
| CarPlay, se autorizzato | Catalogo, scelta libro, Now Playing e disconnessione senza accesso al vecchio CoreData |
| App terminata dal sistema | Download e manifest ripristinati; nessuna promessa di esecuzione dopo un force-quit dell'utente |

La riconciliazione legge la revisione remota prima di scrivere, ma ABS non offre una transazione compare-and-swap per il progresso. Due scritture contemporanee possono ancora sovrapporsi; non ascoltare lo stesso libro simultaneamente su due dispositivi se si vuole evitare questo limite. Il server è configurato senza completamento anticipato negli ultimi dieci secondi, così il client può marcare la fine effettiva del libro.

## Struttura del codice

`Shared/SelfHosted/` è compilato sia in BookPlayerKit sia in BookPlayerWatchKit. `SelfHostedStore` possiede client, player, download e bridge Watch; le view ricevono quel medesimo store. Le entry point iOS/watchOS selezionano la modalità prima di inizializzare i servizi legacy.

- `ABSModels`: contratti API, validazione degli URL/tracce e decisione sui conflitti.
- `ABSClient`: HTTPS, bearer header, redirect rifiutati, catalogo e progresso.
- `ABSLocalStore`: manifest atomico v1 e namespace per account/server.
- `ABSDownloader`: background URLSession, consegna dei temporanei, controllo dimensioni.
- `ABSStreamLoader`: byte range autenticati attraverso resource loader AVFoundation.
- `ABSPlayer`: AVPlayer, offset multipart, audio session, sleep e comandi di sistema.
- `ABSWatchBridge`: credenziali condivise su gesto esplicito; controllo remoto senza credenziali nel contesto.
- `SelfHostedRootView`: UI condivisa, localizzazione inglese/italiano e accessibilità dei comandi.

Qualsiasi modifica futura allo schema `state-v1.json` deve prevedere una migrazione: non resettare una coda pendente per aggirare un errore di decodifica. Non scrivere credenziali nei manifest o nei log. Non trasformare la modalità personale in una falsa abilitazione dell'abbonamento upstream.
