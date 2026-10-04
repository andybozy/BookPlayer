# BookPlayer con cloud personale

Questo ramo mantiene l'app originale: libreria, player, Media Servers, import, navigazione,
download, capitoli e Watch esistenti. Non introduce una nuova app/interfaccia Audiobookshelf.
Le modifiche aggiungono autenticazione e capacità `selfHosted` nel servizio account,
upload multipart e configurazione del backend personale.

## Server

- Cloud/API: `https://bookplayer.androshera.xyz`
- Storage privato: `https://bookplayer-files.androshera.xyz`, URL firmati dal backend.
- Media Servers → Audiobookshelf: `https://audiobooks.androshera.xyz`
- Account iniziale cloud: `andybozy`, stessa password scelta per il listener ABS al momento del provisioning.
  I due account sono indipendenti. Nessuna password, chiave cloud o token è inclusa nell'app/repository.

Il server usa BookPlayer API ufficiale adattato, PostgreSQL e Garage sul media-server.
Configurazione, sorgente backend AGPL, deploy e verifiche sono nel
[repository infrastruttura](https://github.com/andybozy/media_server/tree/main/bookplayer-cloud).
Non usa AWS, RevenueCat, SES o Sentry. Il database autorizza ogni operazione; l'app conserva in Keychain
la capacità ricevuta dal server, legata ad account e dominio, per consentire l'ascolto offline.
La capacità personale non è un acquisto né un abbonamento ufficiale BookPlayer Pro.

## Build da fare successivamente su Mac

Non sono stati eseguiti build, firma, installazione, test Apple o submit su questo server Linux.
I file privati `Debug.xcconfig` / `Release.xcconfig` esistenti non sono stati sovrascritti.

Usare `BuildConfiguration/SelfHosted.template.xcconfig` come override di `xcodebuild -xcconfig`
o includerlo per ultimo nella propria configurazione privata. Impostare il proprio `DEVELOPMENT_TEAM`,
registrare bundle ID e target associati e abilitare i gruppi/provisioning necessari nel proprio account Apple.
Il bundle ID suggerito è `xyz.androshera.BookPlayer`; i target Watch, widget, intent e Share Extension
derivano da `BP_BUNDLE_IDENTIFIER` e devono condividere l'App Group `group.<bundle-id>.files`.

La configurazione personale sceglie entitlements senza CarPlay o Sign in with Apple. Conserva iCloud
Documents e Siri dell'app: richiedono configurazione nel proprio Apple Developer Team. CarPlay richiede
l'autorizzazione Apple prima di aggiungere l'entitlement. Login Apple/passkey non sono attivi in questa
variante: il login locale funziona senza email, AWS o un AASA provvisorio.

Per Xcode Cloud impostare anche `BP_SELF_HOSTED=YES`, i due `BP_*ENTITLEMENTS`, endpoint e bundle ID.
L'upload dSYM richiede ora un'organizzazione/progetto Sentry esplicitamente configurati ed è disattivato
per la build personale; nessun invio al progetto degli autori. La firma e i servizi Apple restano esterni.

## Utilizzo e librerie

1. Nel profilo originale accedere al **Server personale** con username/password.
2. In **Media Servers** aggiungere Audiobookshelf con il dominio e le credenziali ABS.
3. Importare/scaricare i libri desiderati nella libreria BookPlayer; la coda personale sincronizza
   file, progressi, bookmark e preferenze. Un libro solo in streaming ABS non è ancora un file nel cloud.
4. Sul Watch usare il login originale tramite iPhone: il token trasferito viene verificato dal backend,
   senza fidarsi del flag di abbonamento trasferito. La libreria remota e i download sono quelli Watch originali.
5. Nel profilo Watch **Controlla iPhone** permette di tornare ai controlli remoti originali;
   disattivarlo mostra la libreria autonoma. Scaricare il libro sul Watch prima di usarlo senza rete/iPhone.

ABS rimane il catalogo dei file gestiti da Chaptarr; il cloud personale conserva la libreria importata
in BookPlayer e il suo playback. Non replica automaticamente tutto ABS e non sincronizza i progressi
BookPlayer ↔ ABS. I file sincronizzati occupano spazio aggiuntivo sul server, con quota iniziale di 20 GiB.

## Upload e resilienza

Multipart da 8 MiB tramite gli stessi URLSession in background dell'app. Upload ID, dimensione e data
del file persistono in Application Support; alla ripresa viene consultata la lista parti del server.
Le URL firmate sono richieste per ciascuna parte e non ricevono il bearer token BookPlayer.
Ogni risposta upload deve essere HTTP 2xx; solo il completamento verificato dal server conferma il file.
File oltre 10 GiB sono rifiutati. Non c'è ricodifica e non viene caricato tutto il libro in RAM.

Il primo passaggio di sincronizzazione personale usa `/library/status` con UUID: un item remoto già
rinominato non viene registrato di nuovo al percorso locale obsoleto, e gli item eliminati non vengono
ricreati. Le cancellazioni durante la riconciliazione restano bloccate fino al primo passaggio riuscito.
Le code, la persistenza CoreData/SwiftData e i flussi di importazione rimangono quelli originali.

## Validazione

Sul server: build backend, 462 test, upload/download pubblico di oltre 128 MiB, Range, SHA-256,
isolamento account, progressi con rewind, bookmark, preferenze, revoca e quota/riserva.
Sul sorgente Apple: parsing Swift, plist e collegamento del nuovo file a entrambi i framework verificati;
XCTest aggiunti per endpoint personali e limiti multipart, da eseguire su Mac.

Prima dell'uso quotidiano eseguire i test Xcode e queste prove su dispositivi: login/logout anche
durante un upload; due dispositivi con rinomina e progressi; interruzione rete e riapertura app durante
multipart; app sospesa/terminata; impostazione dati mobili; Watch con solo Wi-Fi/LTE e offline, entrambi
i modi di controllo; token revocato e token scaduto; errore quota/disco pieno. Non pubblicare la build
come già validata per questi scenari prima delle prove reali.
