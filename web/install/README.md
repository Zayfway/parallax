# Installation directe

## Ce qui manque pour que ça marche

**Des certificats de signature.** Je ne peux pas les fournir : ce sont des
certificats Apple, liés à un compte. Tout le reste est en place.

## Comment brancher un certificat

1. Signe l'IPA avec ton certificat (Parallax sait le faire, ou n'importe quel
   outil de signature).
2. Héberge l'IPA signé en **HTTPS avec un certificat valide** — iOS refuse
   l'installation autrement. GitHub Releases convient.
3. Ouvre `certificates.json`, remplis l'entrée, passe `enabled` à `true`.
4. Pousse. La page se met à jour toute seule.

Rien d'autre à toucher : la page et les manifestes sont construits à partir de
ce seul fichier.

## Pourquoi trois

Apple révoque les certificats de distribution, régulièrement et sans préavis.
Une app signée avec un certificat révoqué refuse de s'ouvrir. En proposer
plusieurs, c'est garantir qu'il reste un chemin ouvert quand l'un tombe — c'est
le modèle de sideinstaller.net, et il est éprouvé.

L'ordre du fichier est l'ordre d'affichage : mets le plus fiable en premier.

## Le mécanisme

iOS n'installe hors App Store que par `itms-services://?action=download-manifest`,
et il veut un **manifeste plist** décrivant le paquet — jamais l'IPA
directement. `manifest.js` le construit en mémoire et le passe en `data:` URL,
ce qui évite un plist par certificat à maintenir à la main.

Deux contraintes qui ne se contournent pas :

- **Safari uniquement.** Aucune autre app ne peut déclencher `itms-services`.
- **HTTPS valide** sur le manifeste comme sur l'IPA.

## Le profil de configuration

`parallax.mobileconfig` est un gabarit **non signé**, à adapter. Un profil non
signé s'installe encore, mais iOS l'affiche comme « non vérifié ». Le signer
demande un certificat, et c'est la même question qu'au-dessus.
