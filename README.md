# SideSpoofer — architecture

App iOS/iPadOS unifiée : sideloading d'IPA + simulation de localisation système,
entièrement on-device, via le loopback LocalDevVPN.

---

## ⚠️ Trois corrections au brief avant de coder

Ces points changent la charge de travail d'un facteur ~5. Ils sont issus des
`NOTES.md` de SideInstaller et de la doc du crate `idevice`.

### 1. Le pairing on-device est bien propre à iOS 27 — mais pas le protocole

Nuance, et elle compte pour ta matrice de compatibilité. Deux choses distinctes :

- Le **protocole RPPairing** existe depuis **iOS 17.4**. Rien de neuf.
- Ce qui est **neuf en iOS 27**, c'est l'entrée *Pair with Host* dans
  Réglages › Confidentialité et sécurité › Mode développeur, qui permet à
  l'iPhone de se pairer avec un host tournant **sur lui-même**, via le réseau
  local. C'est ça qui supprime le PC.

La doc de Mirage le formule sans ambiguïté : sur iOS 27 l'app fait tourner un
host de pairing sur le téléphone ; sur iOS 18–26, il faut passer par un
ordinateur, et si rien n'apparaît sous *Pair with Host*, c'est que la version
d'iOS ne supporte pas encore le pairing initié par l'appareil.

Conséquence sur ton app : le module 1 fonctionne **uniquement en iOS 27+**. En
dessous, prévois un chemin d'import de fichier RPPairing généré sur un PC avec
`idevice_pair` (mode RPPairing). Ce n'est pas un cas marginal si tu vises un
public large.

**Piège de format :** ce doit être un fichier **RPPairing**. Un
`.mobiledevicepairing` récupéré de SideStore ou StikDebug est au format
*lockdown* classique et ne conviendra pas. SideInstaller documente ce même écart
en sens inverse, quand il écrit le fichier dans le conteneur de SideStore.

### 2. Le cœur Rust ne doit pas réimplémenter lockdownd, la crypto, ni les serveurs Apple

C'est la décision d'architecture la plus importante, et SideInstaller l'a prise
dans l'autre sens que ton brief. Répartition réelle de son code :

| Langage | Part |
|---|---|
| Makefile | 38,4 % |
| C | 38,0 % |
| Swift | 12,0 % |
| **Rust** | **2,4 %** |

Les 38 % de C sont le `idevice.h` généré par cbindgen (8948 lignes). Les 2,4 %
de Rust sont une **fine couche FFI**, pas un cœur protocolaire.

Sa justification, citée :

> Rather than re-implement idevice's threading-sensitive RSD tunnel + service
> clients by hand (untestable here, high risk), `rust-core` depends on both…

Tu t'appuies donc sur trois dépendances qui font tout le travail lourd :

- **`idevice`** (jkcoxson) — Rust pur : lockdownd, RSD, XPC, RemotePairing, DVT,
  AFC, installation_proxy, mobile_image_mounter, `location_simulation`.
- **`idevice-ffi`** — le C-FFI déjà éprouvé, celui que StikDebug embarque.
- **`isideload`** (nab138) — Apple ID, anisette, certificats, profils, signature
  (via `apple-codesign`).

Ton `rust-core/` n'écrit que trois choses : le host RPPairing forké, le pont 2FA,
et le module `location.rs` ci-dessous. C'est tout.

### 3. Il n'existe pas de « Developer Location Service » Apple

Le service réel est **DVT / Instruments** :
`com.apple.instruments.server.services.LocationSimulation`, atteint via le tunnel
RSD. Le crate `idevice` l'expose derrière les features `dvt` +
`location_simulation`. Rien n'a été « étendu en iOS 27 » ; c'est le même canal
qu'utilise `pymobiledevice3 developer dvt simulate-location` depuis iOS 17.

**Coût possible, à vérifier en premier :** dans la chaîne classique
(pymobiledevice3), les services DVT exigent que le **Developer Disk Image soit
monté**, et sur iOS 17+ cette image est *personnalisée* — requête TSS chez Apple
pour un ticket lié au device. D'où les features `mobile_image_mounter` + `tss`
ici, et le dossier `build-dd/` chez SideInstaller.

Mais la doc de Mirage ne mentionne **aucune** étape DDI côté utilisateur : juste
le pairing, puis ça marche. Donc de deux choses l'une — soit elle monte l'image
silencieusement, soit le chemin RSD moderne n'en a pas besoin. **Teste
`ss_ddi_is_mounted` avant d'écrire l'écran de montage.** Si l'image est déjà là,
tu économises l'étape la plus lourde du projet.

**Piège certain :** la localisation simulée ne survit **pas** à la fermeture du
canal DVT. C'est pour ça que `pymobiledevice3 simulate-location` reste bloqué
jusqu'au Ctrl+C — il maintient la session. Ton « self-healing » n'est donc pas un
confort : c'est une exigence structurelle. Voir `LocationEngine.swift`.

**Contrainte réseau, sous-estimée :** iOS n'autorise le *démarrage* du service
de localisation que sur Wi-Fi, partage de connexion ou USB — Apple bloque la
connexion initiale en cellulaire. Une fois la session lancée, elle continue en
5G. Conséquence directe sur le superviseur : si le canal tombe alors que
l'appareil est en données cellulaires, **toute tentative de reconnexion échouera
jusqu'au retour du Wi-Fi**. Une boucle de backoff naïve tournera dans le vide en
brûlant de la batterie. `LocationEngine` surveille donc le type d'interface et
suspend les tentatives au lieu de les empiler.

---

## Recommandation de départ

**Ne réécris pas les modules 1 et 2.** Forke SideInstaller (MIT, `ios-app/` +
`rust-core/` — déjà exactement ton schéma) et ajoute le module 3. Tu récupères
gratuitement le pairing, le tunnel, l'Apple ID, la signature et l'install, tous
déjà débogués sur matériel réel (double-free house_arrest, `Afc(PermDenied)` sur
le mauvais chemin, bundle id `<orig>.<teamID>`… — chacun de ces bugs t'aurait
coûté une soirée).

Le travail neuf se réduit à : montage DDI + session DVT + superviseur + UI carte.

---

## Arborescence

```
sidespoofer/
├── project.yml                    # XcodeGen
├── build-rust.sh                  # → SideSpooferFFI.xcframework
├── rust-core/
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                 # spine de log tracing → callback Swift
│       ├── pairing.rs             # host RPPairing forké de StikPair
│       ├── account.rs             # isideload : login + sign
│       └── location.rs            # ★ neuf : DDI + DVT LocationSimulation
└── ios-app/
    ├── Core/
    │   ├── DeviceConnection.swift # tunnel RSD (recette StikDebug)
    │   ├── PairingStore.swift     # RPPairing → Keychain
    │   └── LocationEngine.swift   # ★ superviseur self-healing
    ├── Location/
    │   ├── GPXTrack.swift         # parsing + interpolation
    │   └── MapScreen.swift        # carte, marqueur, joystick
    └── Sideload/                  # repris de SideInstaller
```

## Ordre de construction

Chaque étape doit tourner sur matériel réel avant la suivante. Le simulateur ne
peut valider ni le pairing, ni le tunnel, ni la DDI, ni la signature.

1. Spine FFI + log console. Vérifiable au simulateur.
2. RPPairing → fichier sur disque, taille non nulle. **Matériel.**
3. Tunnel loopback → `lockdownd_get_value` renvoie ProductVersion. **Matériel.**
4. Montage DDI → `mobile_image_mounter` confirme l'image montée. **Matériel.**
5. Session DVT → une téléportation bouge Plans. **Matériel.**
6. Superviseur, joystick, GPX. Le reste est de l'UI.

Ne passe jamais une étape en « probablement bon ». Chaque gate a une assertion
observable ; si elle n'est pas verte, l'étape suivante échouera de façon
illisible.

## Dépendances à épingler

`idevice` casse son API à chaque version mineure (avertissement explicite du
mainteneur jusqu'en 0.2.0). Épingle sur une révision git, pas sur une plage
sémantique. SideInstaller épingle `7bd551c16c6dd2e058740d85a2d9399a51a776e9`,
alignée sur StikPair et StikDebug — c'est un point de départ connu-bon.

## Vérifications restées ouvertes

- Les signatures exactes de `LocationSimulationClient` dans la révision épinglée
  sont à confirmer contre `cargo doc --open` ; `location.rs` documente
  l'intention, pas une API vérifiée compilée.
- Le projet « Mirage » cité dans le brief est introuvable sur GitHub. Si c'est
  un dépôt privé ou renommé, son approche du montage DDI mérite d'être comparée
  à celle-ci avant d'investir dans l'étape 4.

## Licence et usage

SideInstaller est MIT mais interdit la redistribution de ses builds. Si tu forkes
et publies des IPA, tu redistribues aussi la surface de confiance : n'importe
quel fork de ton app peut y insérer un voleur d'identifiants Apple ID sans que
ce soit visible de l'extérieur. Publie depuis une source unique et dis-le
clairement dans ton README.

La simulation de localisation viole les CGU de la plupart des apps qui s'en
servent comme signal — jeux géolocalisés, partage de position, contrôles d'accès
régionaux. Le bannissement de compte est le risque courant.

---

## Note sur la revendication « 100 % local »

Visible dans les réglages de SideInstaller : le **serveur Anisette** est
`https://ani.sidestore.io`. Anisette est le jeu de données d'attestation
qu'Apple exige pour authentifier un Apple ID hors de ses propres apps, et il ne
peut pas être produit sur un iPhone non jailbreaké. Il est donc **délégué à un
serveur tiers**.

Concrètement, à chaque connexion : ton identifiant Apple et le contexte
d'authentification transitent par une machine que tu ne contrôles pas.

Ce n'est pas un défaut de SideInstaller — c'est structurel, toute la famille
AltStore/SideStore fonctionne ainsi. Mais « vos identifiants ne quittent jamais
votre appareil » est, à la lettre, inexact, et un projet open-source qui reprend
cette phrase telle quelle s'expose à une critique fondée dès la première lecture
attentive.

Formulation défendable :

> Le mot de passe n'est jamais transmis à un serveur tiers. L'authentification
> Apple exige en revanche des données d'attestation (Anisette) produites par un
> serveur relais, configurable dans les réglages. Aucune télémétrie, aucun
> compte, aucun analytics.

Et rends le serveur configurable, comme sur la capture — c'est ce qui permet à
un utilisateur exigeant d'héberger le sien.

## Deux détails d'interface repérés sur les captures

- Le bouton **Installer SideStore** passe sous la barre d'onglets. Un
  `.safeAreaInset(edge: .bottom)` sur le conteneur, ou un `Spacer` de la hauteur
  de la barre en bas du `ScrollView`, règle le problème. C'est l'action
  principale de l'écran : elle ne doit jamais être partiellement masquée.
- Le menu déroulant SideStore / LiveContainer recouvre le sélecteur
  Stable / Nightly pendant qu'il est ouvert. Sans gravité, mais un `Picker` en
  style `.menu` placé au-dessus du segment plutôt qu'en dessous évite le
  chevauchement.

## Sur Mirage, qui est closed-source

Ça ne coûte rien au projet, pour une raison simple : Mirage est une interface
posée sur les mêmes primitives ouvertes que celles utilisées ici. Sa propre
documentation de pairing renvoie à **`idevice_pair` de jkcoxson** en mode
RPPairing — le même auteur, la même stack que `rust-core`. Tout ce que Mirage
fait techniquement est déjà décrit dans pymobiledevice3 et implémenté sous
licence MIT dans `idevice`.

Donc : ne décompile pas son IPA. Ce serait inutile — les mécanismes sont
publics — et ça contaminerait la provenance de ton code au moment de le publier
sous licence libre. Réimplémenter depuis les sources ouvertes est à la fois plus
simple et propre par construction.

Ce qui vaut la peine d'être repris de Mirage, en revanche, ce sont ses
**décisions produit**, qui sont observables sans code : le double moteur
(GPS override / WiFi), le moniteur de santé avec notification quand un spoof
tombe, le fait de dire franchement à l'utilisateur quand la session est perdue.

Une nuance sur son mode WiFi : il exige la signature payante, parce qu'un
tunnel VPN maison réclame l'entitlement Network Extension, indisponible en
provisioning gratuit. Si ton app vise l'Apple ID gratuit, ce mode t'est fermé —
c'est précisément pour ça que Mirage bascule automatiquement sur LocalDevVPN
quand il détecte un sideload gratuit.

---

# Dépôt complet — état réel

## Ce qui est garanti, ce qui ne l'est pas

Je n'ai ni Rust, ni Swift, ni Xcode dans mon environnement. **Rien de ce dépôt
n'a été compilé.** Cette page dit exactement ce que ça implique.

| Partie | État |
|---|---|
| Interface SwiftUI, design, navigation | Écrite en entier. Devrait compiler. |
| Cœur Rust, **profil stub** (défaut) | Ne dépend d'aucune crate externe. Devrait compiler. |
| Cœur Rust, **profil `device`** | Écrit contre la *documentation* d'idevice, jamais compilé. **Attends-toi à corriger des signatures.** |
| Chaîne CI → IPA | Écrite selon la pratique courante. À valider au premier run. |

## Le flag `device`

C'est la décision structurante du dépôt.

Par défaut, `rust-core` compile **sans** idevice ni isideload. Il expose la même
surface C, et chaque fonction renvoie `PX_ERR_NOT_BUILT`. Résultat : le build
passe en quelques secondes sans réseau, la CI est verte, l'IPA s'installe, et
toute l'interface est navigable — carte, joystick, GPX, jumelage, réglages.

C'est délibéré, et voici pourquoi : `idevice` annonce des ruptures d'API à
chaque version mineure jusqu'à 0.2.0, et je n'ai pas lu son code source, juste
sa documentation. Te livrer quarante fichiers qui en dépendent tous aurait
produit, au premier push, une cascade d'erreurs où tu n'aurais pas pu
distinguer mes approximations des vrais problèmes. Une base verte vaut mieux
qu'une base complète et cassée.

Active ensuite **un module à la fois** :

```bash
./build-rust.sh                    # stub — commence ici
./build-rust.sh device-location    # GPS seul
./build-rust.sh device             # tout
```

`Réglages › Version` affiche en permanence le profil compilé. C'est la première
chose à vérifier quand une fonction ne répond pas.

## Ordre de travail

Chaque étape doit tourner sur matériel réel avant la suivante. Le simulateur ne
valide ni le jumelage, ni le tunnel, ni la DDI, ni la signature.

1. **Profil stub → IPA → installation.** Tu vois l'app. `px_ping` doit
   apparaître dans le journal : le pont FFI est sain.
2. **`device-pairing`.** Le code à six chiffres apparaît, Réglages voit
   « Jumeler avec Parallax », le fichier fait plus de zéro octet.
3. **Tunnel.** `lockdownd_get_value` renvoie une ProductVersion. **Matériel.**
4. **`device-location`.** Teste `px_ddi_is_mounted` **avant** d'écrire l'écran
   de montage : si l'image est déjà là, tu économises l'étape la plus lourde du
   projet. Puis une téléportation doit bouger Plans.
5. **`device-account`.** Login, 2FA, certificat, signature, installation.

Ne passe jamais une étape en « probablement bon ». Chaque gate a une assertion
observable ; sans elle, l'étape suivante échoue de façon illisible.

## Points laissés ouverts, volontairement

- `DeviceConnection.connect()` lève une erreur explicite au lieu de simuler un
  succès. Le tunnel RSD est le morceau le plus sensible au threading ; il se
  branche à l'étape 3, contre les signatures vérifiées.
- `CertificatesScreen` est écrit mais n'est câblé à aucun onglet — la barre en
  compte déjà quatre. Ajoute-le en `NavigationLink` depuis Réglages, ou
  remplace un onglet.
- La DDI n'est pas téléchargée : `DDICache` la lit depuis `Documents/ddi/`.
  Décide de la source après avoir vérifié à l'étape 4 si le montage est même
  nécessaire.
- Le `silence.wav` généré fait une seconde. Il suffit, mais vérifie sur
  appareil que la boucle empêche bien la suspension pendant le jumelage.
