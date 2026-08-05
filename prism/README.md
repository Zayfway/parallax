# Prism

Analyse et modification d'apps iOS **on-device**. Un agent injecté scanne et
modifie la RAM d'une app cible (façon GameGuardian) ; un analyseur Mach-O
statique (à venir) trouve les offsets et patche le binaire pour le recompacter.

Frère de [Parallax](../) : même appareil, sans ordinateur. Projet **distinct**,
sous `prism/`, qui ne touche pas Parallax.

## Comment ça marche

Deux processus, un canal loopback :

- **Agent** (`libprism_agent.dylib`) — injecté dans l'app cible (palier 1, via
  l'installeur Parallax). Au chargement, il lève un serveur `127.0.0.1:47821` et
  scanne `mach_task_self()` : régions mémoire, recherche int32, affinage
  (augmenté / diminué / inchangé / = X), lecture et écriture.
- **Hôte** (`Prism.app`) — client du canal. Surface FFI `pr_*` en Rust
  (`prism-core`, exposée par `PrismFFI.xcframework`), UI SwiftUI.

## Build

```sh
cd prism
./build-prism.sh            # PrismFFI.xcframework (host, feature agent-link)
./build-agent.sh            # libprism_agent.dylib (à injecter dans la cible)
xcodegen generate --spec prism.yml
xcodebuild archive -project Prism.xcodeproj -scheme Prism ...
```

Ou par CI : `build-prism-ipa.yml` (dispatch manuel, ou tag `prism-v*`).

## Jalon 1

Colonne vertébrale : injecter l'agent → connecter → lister les régions →
**une** recherche int32 → **une** passe d'affinage → **une** écriture confirmée
par relecture. Quand l'écriture prend, l'ambre déborde sur la barre d'onglets —
et nulle part ailleurs.

Voir `CLAUDE.md` pour l'architecture, les conventions FFI et les pièges.

## Licence

Même licence que le dépôt (voir `../LICENSE`).
