# Parallax

**Sideloading d'IPA + spoofing GPS, entièrement sur l'iPhone. Sans Mac, sans PC, sans câble.**

Parallax réunit deux outils qui, jusqu'ici, marchaient chacun de leur côté mais
jamais sans ordinateur : installer des applications hors App Store (SideStore,
LiveContainer) et **déclarer la position GPS de ton choix**. Toute la chaîne —
compte Apple, certificat, signature, transfert, installation — tourne sur
l'appareil. Cible **iOS 17.4+**, testé sur iOS 27.

Interface **SwiftUI**, cœur natif en **Rust** (exposé en `ParallaxFFI.xcframework`),
builds produits publiquement par **GitHub Actions**.

> [!NOTE]
> Code **source visible** : tu peux tout lire et tout compiler, mais pas le
> modifier ni le redistribuer. Voir [Licence](#licence).

---

## Ce que ça fait

### 📦 Sideloading, sans ordinateur
- **Jumelage RPPairing** initié par l'appareil : « Jumeler avec Parallax »
  apparaît dans *Réglages › Confidentialité et sécurité › Mode développeur*, un
  code s'affiche, et le lien s'établit — par le **tunnel VPN loopback**, pas par
  le Wi-Fi.
- **Compte Apple** complet : anisette, 2FA appareil de confiance, session
  développeur.
- **Certificats** : liste, **génération** et révocation. Le nombre
  d'emplacements vient d'Apple, pas d'une limite écrite en dur.
- **Installation** : télécharge, **signe avec ton propre certificat**, transfère
  et installe **SideStore** ou **LiveContainer**. Tu vois passer chaque étape,
  avec un journal en direct.
- **N'importe quel IPA** (« Autre IPA ») : importe un `.ipa` ou colle une URL, et
  installe-le signé avec ton compte.
- **Injection de tweaks** (comme Feather) : `.dylib` autonome, ou `.deb` complet
  — la **Substrate** est réécrite vers **ElleKit** et les dépendances embarquées
  (3 paliers). Options **Injection Path / Folder / Inject into Extensions**.
- **Signer sans compte Apple** : importe un certificat **`.p12` + profil
  `.mobileprovision`** ; la signature se fait **hors-ligne**, sur l'appareil.
- **Propriétés d'app** : renommer, changer l'identifiant pour **dupliquer** une
  app (deux copies côte à côte).

### 🛍️ Sources — un magasin d'apps
- Ajoute l'**URL d'une source** (format AltStore / SideStore) et parcours son
  catalogue : icône, développeur, description, version.
- **Recherche** dans toutes les sources, **fiche produit** par app.
- « **Envoyer à l'Installeur** » dépose l'IPA dans l'Installeur, où tu choisis
  la signature — Sources ne fait que la vitrine.

### 🔧 Atelier — inspecter un IPA avant de l'installer
- Importe un `.ipa` (aucun appareil requis) et Parallax le radiographie :
  **architectures** (arm64 / arm64e…), **chiffrement** (déchiffré ou verrouillé
  App Store), **frameworks & extensions** embarqués, **bibliothèques liées**.
- **Profil de provisionnement** : type, équipe, validité, `get-task-allow`.
- De là, **envoi direct à l'Installeur**, ou partage du rapport.

### 📚 Bibliothèque — gérer les apps installées
- **Liste** de toutes les apps (icônes réelles, taille de stockage, version).
- **Filtre** : sideloadées (cert/IPA) · App Store · toutes. **Recherche** et
  **tri** (nom / taille).
- **Désinstalle** n'importe quelle app, **fiche détaillée** par app.

### 📁 Fichiers — l'espace Média de l'appareil
- **Parcourir** `/var/mobile/Media` (photos, téléchargements, fichiers) par AFC.
- **Télécharger & partager**, **aperçu** (QuickLook), **importer**, **renommer**,
  **supprimer**, **créer un dossier**, **recherche** et **tri**, jauge de
  **stockage**.

### 💾 Sauvegardes — protéger les données d'une app
- Une signature gratuite **expire en 7 jours** ; à la réinstallation, iOS efface
  le conteneur. Archive-le d'abord dans un **`.zip`** (à garder ou partager).
- **Restaure** un `.zip` dans l'app après réinstallation — progression, réglages
  et fichiers reviennent. Via `house_arrest`, pour les apps sideloadées.

### 🔐 Profils & 🩺 diagnostic
- **Profils de provisionnement** : liste (nom, app id, validité) et **retrait**
  d'un profil expiré ou en trop qui bloquerait une installation.
- **Diagnostic appareil** : nom, modèle, version iOS, **batterie** — lus par le
  tunnel, sans image développeur.

### 📍 Position simulée
- **Point posé** sur la carte, ou **recherche d'adresse** (barre de recherche →
  adresse exacte).
- **Itinéraire** : voiture, vélo, marche (routes réelles via MapKit) ou avion
  (orthodromie), avec **choix de la vitesse**.
- **Boucle**, **pause / reprise**, barre d'avancement.
- **Import GPX**, **joystick** de déplacement au pouce, **lieux enregistrés**.
- **Partage d'un point** : QR code + lien `parallax://locate` — un ami scanne et
  se retrouve au même endroit.
- **Mode furtif** (bruit GPS réaliste) et **flânerie** (le point se promène tout
  seul à allure piéton) : une position simulée qui *respire* au lieu d'être
  gelée — ce que traquent Snap Map, Life360 & co.
- **Point de position réelle** affiché sur la carte, session supervisée qui se
  rétablit après une micro-coupure du tunnel.

---

## Comment ça marche, point par point

1. **Un VPN loopback.** Installe **LocalDevVPN** ou **StosVPN** et touche
   *Connect*. C'est lui qui fournit l'adresse locale (`10.7.0.1`) par laquelle
   Parallax parle à l'appareil. **Sans lui, rien ne se connecte.**
2. **Le jumelage.** Parallax s'annonce sur le réseau local. Va dans
   *Réglages › Confidentialité et sécurité › Mode développeur*, touche
   « Jumeler avec Parallax », recopie les six chiffres. Fait **une seule fois**.
3. **Ton compte Apple.** Il sert à signer et à enregistrer l'appareil auprès
   d'Apple. Le mot de passe ne quitte pas l'appareil ; l'attestation Apple passe
   par un relais **Anisette** (voir [Honnêteté](#honnêteté)).
4. **Installe.** Choisis SideStore ou LiveContainer : téléchargement, signature,
   transfert et pose sur l'écran d'accueil s'enchaînent.
5. **Simule ta position** (indépendant du reste) : ouvre l'onglet Carte, pose un
   point ou lance un trajet.

---

## De quoi tu as besoin, selon ton cas

| Ton cas | Ce qu'il te faut |
|---|---|
| **iOS 17.4 – 26** | Un fichier de jumelage RPPairing importé (généré une fois sur PC), puis tout fonctionne sur l'appareil. |
| **iOS 27+** | Rien de plus : le jumelage sans ordinateur est intégré. |
| **Installer des apps** | Un compte Apple + LocalDevVPN/StosVPN. |
| **Seulement le GPS** | Le jumelage (ou le fichier importé) + LocalDevVPN. Pas besoin de compte Apple. |

---

## Installer Parallax

L'IPA est **non signé, volontairement** : signer côté serveur imposerait de
déposer une clé privée Apple dans un dépôt public. Tu le signes toi-même, avec
ton propre certificat.

1. Télécharge la **[dernière version](https://github.com/Zayfway/parallax/releases/latest)**
   (`Parallax.ipa`).
2. Ouvre-le avec **SideStore**, **AltStore** ou **Feather** : ils le
   re-signent avec ton compte Apple gratuit, directement sur l'appareil.
3. La signature gratuite expire au bout de 7 jours ; SideStore/AltStore la
   renouvellent tout seuls en arrière-plan.

Un **site** guide l'installation pas à pas : voir [`web/`](web/) (publié sur
GitHub Pages).

---

## Compiler depuis les sources

```bash
# 1. Le xcframework Rust (les deux cibles + assemblage)
./build-rust.sh device          # ou : device-pairing,device-account | device-location

# 2. Le projet Xcode
brew install xcodegen && xcodegen generate

# 3. Archiver (non signé)
xcodebuild archive -project Parallax.xcodeproj -scheme Parallax \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Parallax.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

La CI (`.github/workflows/build-ipa.yml`) fait exactement ça à chaque push sur
`main` et publie l'IPA dans la [release](https://github.com/Zayfway/parallax/releases/latest).

### Profils de compilation

`device-location`, `device-pairing`, `device-account`, ou `device` (les trois).
En profil *stub* (aucune feature), l'interface est complète mais aucune
opération sur l'appareil n'aboutit — utile pour travailler l'UI.

---

## Architecture

```
ios-app/         SwiftUI. Rien n'appelle px_* hors de Core/FFI.swift.
rust-core/       Crate parallax-ffi, exposé en ParallaxFFI.xcframework.
                 build.rs génère include/parallax.h via cbindgen.
build-rust.sh    Compile les deux cibles et assemble le xcframework.
web/             Le site (HTML/CSS), publié sur GitHub Pages.
```

**Répartition Rust / Swift**, apprise à la dure :

| Rust | Swift |
|---|---|
| protocole RPPairing, écoute TCP | annonce Bonjour (`NetService`) |
| compte Apple, signature | autorisation réseau local |
| session GPS via DVT | maintien en vie (audio silencieux) |

### Dépendances épinglées

- [`idevice`](https://github.com/jkcoxson/idevice) — jkcoxson, rev `7bd551c1`
- [`isideload`](https://github.com/nab138/isideload) — nab138, v0.2.25 (rev
  `86b2540a`), licence MIT

Ces révisions ne doivent **pas** changer sans raison : `isideload` tire aussi
`idevice` depuis crates.io, et les deux crates doivent coexister sans fusionner
(l'étape CI « symboles dupliqués » y veille).

---

## Honnêteté

Ton mot de passe Apple ne quitte pas l'appareil. Mais l'authentification Apple
exige des données d'attestation — **Anisette** — qu'un iPhone non jailbreaké ne
peut pas produire seul : elles viennent d'un serveur relais tiers. Autrement dit,
l'identifiant et le contexte d'authentification transitent par une machine que tu
ne contrôles pas. Ce n'est pas propre à Parallax, c'est **structurel à toute la
famille AltStore / SideStore** — et le serveur Anisette est configurable dans les
réglages. Écrire « vos identifiants ne quittent jamais votre appareil » serait
faux, donc on ne l'écrit pas.

---

## Licence

**Code source visible, sans modification** — voir [`LICENSE`](LICENSE).

Tu peux lire tout le code et le compiler pour toi ; tu ne peux pas le modifier
ni le redistribuer sans autorisation. **Utiliser l'application est libre et
gratuit pour tout le monde** — la licence ne concerne que le code source. Les
dépendances tierces gardent leurs propres licences.

---

## Avertissement

Non affilié à Apple. SideStore, AltStore et LiveContainer appartiennent à leurs
auteurs respectifs. Cet outil est fourni pour l'apprentissage et l'usage
personnel ; tu es responsable de ce que tu en fais.
