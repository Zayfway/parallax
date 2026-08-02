/* ═══════════════════════════════════════════════════════════════════════════
   INSTALLATION DIRECTE

   iOS n'installe une app hors App Store que par `itms-services`, et il exige
   un **manifeste plist** décrivant le paquet — pas l'IPA directement. Le
   manifeste doit être servi en HTTPS avec un certificat valide, tout comme
   l'IPA qu'il désigne.

   Le manifeste est construit ici, en mémoire, puis passé en `data:` URL. Ça
   évite d'avoir un fichier plist par certificat à maintenir à la main, et ça
   garde `certificates.json` comme unique source de vérité.

   ⚠️ Certains iOS refusent une `data:` URL dans `itms-services`. Le repli
   automatique est un plist statique déposé à côté ; la page le tente si le
   premier chemin ne prend pas.
   ═══════════════════════════════════════════════════════════════════════════ */

const escapeXML = (value) =>
  String(value).replace(/[<>&'"]/g, (c) =>
    ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]));

export function buildManifest({ ipa, bundleIdentifier, version, title }) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>${escapeXML(ipa)}</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>${escapeXML(bundleIdentifier)}</string>
    <key>bundle-version</key><string>${escapeXML(version)}</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>${escapeXML(title)}</string>
  </dict>
</dict></array></dict></plist>`;
}

export function installURL(manifest) {
  const encoded = encodeURIComponent(
    'data:application/xml;base64,' + btoa(unescape(encodeURIComponent(manifest)))
  );
  return `itms-services://?action=download-manifest&url=${encoded}`;
}
