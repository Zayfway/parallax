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

**Fonctionne sur appareil :**

- Connexion Apple complète — anisette, 2FA appareil de confiance, session
  développeur, jeton `com.apple.gs.xcode.auth`
- Jumelage RPPairing sans ordinateur : l'entrée « Pair with Parallax » apparaît
  dans Réglages › Mode développeur, le PIN s'affiche, le fichier est écrit
- CI : Rust, symboles, xcodegen, archive, IPA

**Écrit mais jamais exécuté :** signature d'IPA (`px_sign_ipa`).

**À faire :**

1. **Certificats** — `imp::list_certs` / `imp::revoke_cert` sont dans
   `account.rs`, les entrées FFI (`px_cert_list`, `px_cert_revoke`,
   `px_string_free`) restent à ajouter, puis l'écran à câbler.
   Le compte est payant : la limite de trois affichée est fausse.
2. **Installation** — enregistrer l'appareil (`ensure_device_registered`, sinon
   erreur Apple **8220**), `sign_app`, puis AFC + `installation_proxy` par le
   tunnel RSD. **Ne pas** utiliser `isideload::install_app` : il exige un
   `IdeviceProvider` avec un `PairingFile` lockdown, incompatible avec le
   RPPairing produit ici. SideInstaller ne l'utilise pas non plus.
3. **GPS** — `location.rs:270`, `RsdService is not general enough` sur
   `runtime.spawn`. Ni `&'static mut` ni turbofish ne suffisent : la contrainte
   est d'ordre supérieur. Piste : contourner `connect_rsd` et appeler
   `<RemoteServerClient<Box<dyn ReadWrite>> as RsdService>::from_stream(...)`,
   comme le fait `idevice-ffi` pour ses services génériques.

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
