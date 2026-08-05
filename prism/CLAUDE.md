# Prism — contexte projet

Outil iOS open-source d'**analyse et de modification d'apps**, entièrement
on-device. Deux moitiés : un **agent injecté** qui scanne et modifie la RAM
vive d'une app cible (façon GameGuardian), et un **analyseur Mach-O statique**
(offsets, patch, recompactage — jalon 2). Frère optique de Parallax : Parallax
déplace ta position, Prism décompose une app en ses composants cachés.

Dépôt : `Zayfway/parallax`, dossier `prism/`. Cible iOS 17.4+.

> **RÈGLE D'OR : Prism ne touche AUCUN fichier Parallax existant.** Seule
> empreinte tolérée hors `prism/` : le workflow CI (fichier neuf, obligatoirement
> à la racine `.github/workflows/`) et trois lignes additives au `.gitignore`
> racine. La logique d'`inject.rs` / `inspect.rs` de Parallax est **adaptée**
> dans Prism, jamais importée depuis le crate Parallax.

---

## Architecture

```
prism/
  prism-proto/   contrat de fil host<->agent (enums Cmd/Reply serde). Source unique.
  prism-core/    côté HÔTE — surface FFI pr_*, exposée en PrismFFI.xcframework.
                 build.rs génère include/prism.h via cbindgen.
  prism-agent/   côté CIBLE — dylib cdylib injecté (mach_task_self, scan/écriture).
  prism-ios/     SwiftUI. Rien n'appelle pr_* hors de Core/FFI.swift.
  build-prism.sh assemble PrismFFI.xcframework (host).
  build-agent.sh compile le dylib agent, pose l'install_name.
```

**Modèle mental : deux processus, un canal loopback.**

```
┌─ App CIBLE ──────────────────┐         ┌─ App PRISM ──────────────────┐
│ libprism_agent.dylib         │  TCP    │ Prism.app                    │
│  #[ctor] → serveur 127.0.0.1 │◄───────►│  PrismFFI.xcframework        │
│  mach_task_self : régions,   │127.0.0.1│  prism-core : client + pr_*  │
│  scan i32, refine, r/w       │ :47821  │  SwiftUI (DesignSystem PR)   │
└──────────────────────────────┘         └──────────────────────────────┘
```

L'agent scanne **sa propre tâche** (`mach_task_self()`) une fois injecté :
pas de `task_for_pid`, pas d'entitlement privilégié. Modèle in-process.

**Répartition Rust / Swift** :

| Rust | Swift |
|---|---|
| énumération des régions (`mach_vm_region` sur `mach_task_self`) | rendu de la liste, filtres lisibles |
| recherche int32, candidats, affinage (▲▼≈=) | machine à phases scan→affine→écrit, rail |
| lecture / écriture / `vm_protect` de la cible | déclenchement écriture, bascule ambre « modif active » |
| serveur loopback dans l'agent, `#[ctor]` au chargement | autorisation réseau local |
| client TCP + protocole (`prism-proto`) | gestion du handle `PrSession` |
| `guard`/`catch_unwind`, `set_last_error`, JSON | `FFI.check`, `defer pr_string_free`, décodage |
| analyseur Mach-O statique, patch d'octets (**jalon 2**) | Atelier d'inspection (**jalon 2**) |

### Pas de workspace cargo racine

Il n'existe **aucun `Cargo.toml` racine** dans le dépôt — c'est ce qui isole
`rust-core` (Parallax) de `prism-*`. **Ne jamais en créer** : un `[workspace]`
racine fusionnerait la résolution de features de `rust-core` et pourrait casser
son étape CI « symboles dupliqués ». Les trois crates Prism sont autonomes,
reliées par dépendance `path` à `prism-proto`, chacune avec son `Cargo.lock`.

### Isolation vis-à-vis de Parallax (noms re-namespacés)

`prism_core` / `PrismFFI.xcframework` / `prism.h` / guard `PRISM_H` /
`io.prism.app` / schéme `prism` / tag `prism-v*` (jamais `v*`) / cache
`cargo-prism-*` / artefact `Prism-ipa` / spec `prism.yml` (pas `project.yml`).
CI sans étape « symboles dupliqués » (pas de double `idevice`).

### Profils de compilation

`agent-link` (défaut CI, lien mémoire vive) · `static-macho` (jalon 2, analyse
statique) · `full`. Hors feature → stub, `PR_ERR_NOT_BUILT`, sans réseau.
`build_profile()` dans `lib.rs` doit reconnaître **chaque** combinaison, sinon
les Réglages affichent « stub » alors que le natif est là.

---

## Conventions FFI (héritées de Parallax)

- Codes `PR_OK` / `PR_ERR_*` (mêmes familles numériques). **Asymétrie
  `NOT_BUILT`** : une fonction rendant `c_int` **rend le code** ; une fonction
  rendant un pointeur rend `NULL` + `set_last_error`.
- Canal d'erreur unique (`LAST_ERROR`, `pr_last_error` emprunté). `guard()` +
  `catch_unwind`. `cstr()` pour lire les entrées.
- **Un seul** libérateur : `pr_string_free`. Le tas appartient à Rust ; Swift
  pose `defer { pr_string_free(raw) }` **avant** tout décodage.
- Handles opaques (`PrSession`) via `Box::into_raw`/`Box::from_raw` ;
  `pr_session_close` **consomme** le pointeur. `/// cbindgen:opaque`.
- `build.rs` (cbindgen doxy) génère `prism.h`. Callbacks `extern "C"` sans capture.

---

## Système de design

`prism-ios/DesignSystem.swift` — copie namespacée de Parallax (`PX` → `PR`),
mêmes tokens. **Deux règles absolues :**

1. **L'ambre `PR.Color.signal` signifie « modification active en mémoire », et
   rien d'autre.** Une valeur écrite/figée dans la RAM de la cible. Jamais
   décoratif. Le reste : azimuth = scan/affinage, verdant = candidat verrouillé,
   alert = échec. `signalGlow` est le seul halo ambré. La pastille d'`InstrumentStrip`
   **exclut** l'ambre ; la teinte déborde sur la barre d'onglets via `.tint`.
2. **Mono = valeur machine** (adresses, i32, protections, tags). **Rounded =
   adressé à l'humain.** Si c'est en mono, ça vient de la mémoire de l'appareil.

Coquille : `ZStack{ canvas; ScrollView{ VStack{ ScreenHeader; cartes.appear(i,shown) } } }`.
`ScanScreen.swift` est la référence de composition : machine à `enum Phase`
dérivée, banner unique coloré, rail d'étapes, cascade. `PR.Motion` nommé
(`acquire` = l'aboutissement, ici l'écriture qui prend).

---

## Le canal loopback

Agent = serveur `127.0.0.1:47821` (`PR_AGENT_PORT`) lancé par `#[ctor]` au
chargement du dylib, sur un thread détaché (ne jamais bloquer le démarrage de
la cible). Hôte = client TCP. Protocole **ligne-JSON** (`prism-proto`).
Connexions loopback = exemptes du prompt réseau local (127.0.0.1).

Injection au jalon 1 : passer `libprism_agent.dylib` comme dylib à l'installeur
Parallax (palier 1 autonome). Aucun code d'injection à écrire côté Prism.

---

## Pièges déjà payés (à remplir au fil de l'eau)

- **Callback FFI en portée fichier** (`prScanLog`) — une closure `@MainActor`
  hériterait l'isolation et le runtime trappe (`swift_task_checkIsolated`).
- **FFI bloquant sur `DispatchQueue.global`, jamais dans une `Task`** (pool
  coopératif = un thread par cœur).
- `usize`/`u64` Rust ↔ `UInt`/`UInt64` Swift, **jamais `Int`**.
- `cdylib` agent volontairement **mince** (mach2/ctor/std) pour linker sur
  device, là où le FFI hôte reste `staticlib+rlib`.
- L'agent scanne `mach_task_self()` — pas de `task_for_pid`, pas d'entitlement.

---

## État

**Jalon 1 (colonne vertébrale) — posé, à valider sur device :**
- `prism-core` compile en stub (sans réseau) et sous `agent-link` ; header
  cbindgen propre, 12 symboles `pr_*`, `PrSession` opaque. **Vérifié en CI native.**
- Agent : serveur loopback + scan i32 / affinage / lecture / écriture via
  `mach_vm_*`. Code mach première passe — **à confirmer sur appareil**.
- SwiftUI : connexion, recherche, affinage (▲▼≈=), régions, écriture qui allume
  l'ambre. Machine à phases + rail + cascade.
- CI : `build-prism-ipa.yml` (PR/tag/dispatch), tag `prism-v*`, `make_latest:false`.

**À faire :**
1. Valider la chaîne complète sur appareil (injection → connexion → scan →
   écriture confirmée par relecture).
2. **Jalon 2 — analyseur Mach-O statique** (`static-macho`) : symboles, chaînes,
   métadonnées ObjC, scan de signatures AOB, désassemblage ARM64 (capstone),
   patch d'octets + recompactage + re-signature (réutilise la chaîne Parallax).
3. Figeage périodique (freeze), recherche typée (float/double), pont chaud↔froid
   (adresse vivante → offset statique).
4. Dump du binaire déchiffré depuis l'agent (apps App Store FairPlay).
