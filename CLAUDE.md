# Parallax — contexte projet

App iOS open-source réunissant **sideloading d'IPA** et **spoofing GPS**, entièrement
on-device, sans ordinateur. Cible iOS 17.4+, testée sur iOS 27.

Dépôt : `Zayfway/parallax`. Développé depuis un iPhone (iSH + SSH), builds par
GitHub Actions, IPA non signé réinstallé via SideStore.

---

## Architecture

```
ios-app/         SwiftUI. Rien n'appelle px_* hors de Core/FFI.swift.
rust-core/       Crate parallax-ffi, exposé en ParallaxFFI.xcframework.
                 build.rs génère include/parallax.h via cbindgen.
build-rust.sh    Compile les deux cibles et assemble le xcframework.
```

**Répartition Rust / Swift** — apprise à la dure, ne pas l'inverser :

| Rust | Swift |
|---|---|
| protocole RPPairing, écoute TCP | annonce Bonjour (`NetService`) |
| compte Apple, signature | autorisation réseau local |
| session GPS via DVT | maintien en vie (audio silencieux) |

### Dépendances épinglées

- `idevice` — jkcoxson, rev `7bd551c1` (git)
- `isideload` — nab138, branche `main`, v0.2.25 (rev `86b2540a`), licence MIT
- Clones de référence dans `~/ref/` aux mêmes révisions

`isideload` tire aussi `idevice` 0.1.65 depuis crates.io. Les deux coexistent
comme crates distincts ; l'étape CI « symboles dupliqués » veille à ce qu'ils ne
fusionnent pas.

### Profils de compilation

`device-location`, `device-pairing`, `device-account`, et `device` (les trois).
Le workflow compile par défaut `device-pairing,device-account` — le GPS est
exclu tant que l'erreur `RsdService` n'est pas réglée.

`build_profile()` dans `lib.rs` doit reconnaître chaque combinaison, sinon les
Réglages affichent « stub » alors que le natif est bien là.

---

## État

**Fonctionne sur appareil (chaîne complète, sans ordinateur) :**

- Connexion Apple complète — anisette, 2FA appareil de confiance, session
  développeur, jeton `com.apple.gs.xcode.auth`
- Jumelage RPPairing sans ordinateur : l'entrée « Pair with Parallax » apparaît
  dans Réglages › Mode développeur, le PIN s'affiche, le fichier est écrit
- Tunnel : RPPairing → RSD par le **VPN loopback** (10.7.0.1:49152), pas par
  Bonjour/Wi-Fi. `tunnel.rs` monte adapter + RSD + services.
- Certificats : liste, **génération** et révocation (`px_cert_list`,
  `px_cert_create`, `px_cert_revoke`) ; le nombre d'emplacements vient d'Apple
  (`maxActiveCerts`), pas d'une limite écrite en dur.
- Installation : `ensure_device_registered` (avant signature, sinon Apple 8220)
  → `sign_app` → **re-zip du Payload** → `install_bytes_with_callback_rsd`
  (Install et non Upgrade). Cible SideStore **et** LiveContainer.
- GPS : point posé, **itinéraire** (voiture/vélo/marche/avion + vitesse), import
  GPX, joystick, **boucle**, **pause/reprise**, **favoris**. Session supervisée
  qui se rétablit après une micro-coupure du tunnel.
- CI : Rust, symboles, xcodegen, archive, IPA. Release taguée avec l'IPA.

**À faire :**

1. **Refonte du design (forme/style)** — demandée par l'auteur, à lancer à son
   signal explicite. `DesignSystem.swift` reste la référence ; ne pas le
   réécrire à l'aveugle.
2. **Distribution publique** — `web/install/` a trois emplacements de
   certificats interchangeables, désactivés tant qu'aucun certificat de
   signature légitime n'est fourni. L'auteur alimente les IPA signés.

**Pièges corrigés (pour ne pas les rejouer) :**

- `LiveContainer` est une **app distincte** (`LiveContainer/LiveContainer`,
  `releases/latest/LiveContainer.ipa`). L'ancien `SideStore-LiveContainer.ipa`
  n'existe plus (404).
- Dans `LocationEngine.tick`, `guard let source` masque la propriété : écrire
  `self.source` pour figer la position en fin de trace.
- Le GPS **fonctionne** : `location.rs` contourne `connect_rsd` (la contrainte
  `RsdService is not general enough` naissait dans son corps) en résolvant le
  port du service dans `rsd.services`, puis `RemoteServerClient::new`.

---

## Pièges déjà payés

**Isolation d'acteur.** `SWIFT_STRICT_CONCURRENCY: minimal` ne vérifie rien à la
compilation, mais le runtime trappe (`EXC_BREAKPOINT`, `swift_task_checkIsolated`).
Une closure C définie dans un contexte `@MainActor` en hérite, et Rust l'appelle
depuis ses threads. Tout callback passé au FFI doit être en **portée fichier**.

**Appels FFI bloquants.** Jamais dans une `Task` : le pool coopératif a un thread
par cœur. `DispatchQueue.global(qos:)`.

**Bonjour.** Une bibliothèque mDNS pure (`mdns-sd`) publie les adresses de toutes
les interfaces — un iPhone en a cinq, dont le tunnel VPN. iOS tente une adresse
injoignable et l'entrée reste grise avec un rouet. Passer par `NetService`, et
déclarer chaque type de service dans `NSBonjourServices` — un type non déclaré
fait **tuer le processus**, pas échouer l'appel.

**Types.** `usize` Rust = `UInt` Swift, pas `Int`.

**GitHub depuis mobile.** Éditer un fichier existant : ouvrir, crayon,
**tout sélectionner, supprimer**, puis coller. Sinon le contenu s'ajoute sous
l'ancien et le build voit un doublon.

**iSH.** BusyBox : pas de `--include` pour grep, pas de `python3`, pas de
globs `**`, `awk` limité. Les heredocs longs se tronquent — préférer plusieurs
petits blocs, et vérifier avec `tail` avant de commiter.

---

## Système de design

`ios-app/DesignSystem.swift` définit tout : `PX.Color`, `PX.Font`, `PX.Radius`,
`PX.Space`, `PX.Motion`, plus `glassCard`, `ProminentButtonStyle`, `.field()`,
`InstrumentStrip`.

Deux règles absolues :

- **L'ambre (`PX.Color.signal`) signifie « position simulée active », et rien
  d'autre.** Jamais ailleurs. Pour le reste : pervenche en cours, vert terminé,
  rouge échec.
- **Mono = valeur machine** (coordonnées, IP, empreintes). **Rounded = adressé à
  l'humain.** Si c'est en mono, ça vient de l'appareil.

Les animations passent par le vocabulaire nommé de `PX.Motion` — `tap`,
`settle`, `acquire`, `breathe`, `stagger(i)` — jamais de courbes improvisées.
`PairingScreen.swift` est la référence : machine à phases, rail d'étapes,
entrées en cascade.
