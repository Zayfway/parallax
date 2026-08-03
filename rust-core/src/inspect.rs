//! Atelier — inspection **locale** d'un IPA.
//!
//! Aucune connexion à l'appareil : on lit le `.ipa` (un zip) sur place. C'est
//! l'outil qui manquait au sideloader — savoir *ce qu'on installe* avant de le
//! poser : quelles architectures, l'app est-elle déchiffrée (sinon elle ne
//! tournera signée que sur l'appareil d'origine), quels frameworks embarqués,
//! quel profil de provisionnement, quelles habilitations. On réutilise les
//! mêmes briques que l'injection (`zip`, lecture Mach-O brute) et que les
//! profils (`plist`), sans le tunnel.
//!
//! Rend un JSON, NULL en cas d'échec dur (zip illisible, pas de `Payload`).

#![cfg(feature = "device-account")]

use crate::*;
use std::io::Read;

/// Inspecte l'IPA à `path`. Rend un JSON décrivant l'app, ou NULL. À libérer
/// par `px_string_free`.
///
/// # Safety
/// `path` : chemin UTF-8 terminé par NUL vers un `.ipa` lisible.
#[no_mangle]
pub unsafe extern "C" fn px_ipa_inspect(path: *const c_char) -> *mut c_char {
    clear_last_error();
    let Some(p) = cstr(path) else {
        set_last_error("px_ipa_inspect : chemin nul");
        return ptr::null_mut();
    };
    if p.is_empty() {
        set_last_error("px_ipa_inspect : chemin vide");
        return ptr::null_mut();
    }
    guard("px_ipa_inspect", ptr::null_mut(), || match imp::inspect(&p) {
        Ok(json) => CString::new(json)
            .map(|c| c.into_raw())
            .unwrap_or(ptr::null_mut()),
        Err(e) => {
            set_last_error(e);
            ptr::null_mut()
        }
    })
}

mod imp {
    use super::*;
    use std::fs::File;

    pub fn inspect(path: &str) -> Result<String, String> {
        let file_size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        let file = File::open(path).map_err(|e| format!("ouverture de l'IPA : {e}"))?;
        let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("archive illisible : {e}"))?;

        // Noms de toutes les entrées, pour repérer le bundle et ses annexes.
        let names: Vec<String> = zip.file_names().map(String::from).collect();

        // Le préfixe du bundle : « Payload/Xxx.app/ ». On le déduit de la
        // première Info.plist rencontrée directement sous un .app.
        let app_prefix = names
            .iter()
            .find_map(|n| {
                let rest = n.strip_prefix("Payload/")?;
                let app = rest.split('/').next()?;
                if app.ends_with(".app") && n == &format!("Payload/{app}/Info.plist") {
                    Some(format!("Payload/{app}/"))
                } else {
                    None
                }
            })
            .ok_or("IPA sans Payload/<App>.app/Info.plist — format inattendu")?;

        // ── Info.plist ──────────────────────────────────────────────────────
        let info_bytes = read_entry(&mut zip, &format!("{app_prefix}Info.plist"))
            .ok_or("Info.plist introuvable")?;
        let info = plist::Value::from_reader(std::io::Cursor::new(&info_bytes))
            .map_err(|e| format!("Info.plist illisible : {e}"))?;
        let info = info.as_dictionary().ok_or("Info.plist n'est pas un dictionnaire")?;

        let s = |k: &str| info.get(k).and_then(|v| v.as_string()).map(String::from);
        let executable = s("CFBundleExecutable").unwrap_or_default();
        let name = s("CFBundleDisplayName")
            .filter(|v| !v.is_empty())
            .or_else(|| s("CFBundleName"))
            .unwrap_or_else(|| executable.clone());

        // Familles d'appareils : 1 = iPhone, 2 = iPad.
        let device_families: Vec<i64> = info
            .get("UIDeviceFamily")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|v| v.as_signed_integer()).collect())
            .unwrap_or_default();

        // ── Exécutable Mach-O : architectures + chiffrement + dylibs liés ────
        let mut archs: Vec<String> = Vec::new();
        let mut encrypted = false;
        let mut linked: Vec<String> = Vec::new();
        if !executable.is_empty() {
            if let Some(bin) = read_entry(&mut zip, &format!("{app_prefix}{executable}")) {
                let macho = parse_macho(&bin);
                archs = macho.archs;
                encrypted = macho.encrypted;
                linked = macho.dylibs;
            }
        }

        // ── Annexes embarquées : frameworks, plugins, dylibs à la racine ────
        let mut frameworks: Vec<String> = Vec::new();
        let mut plugins: Vec<String> = Vec::new();
        let mut loose_dylibs: Vec<String> = Vec::new();
        for n in &names {
            if let Some(rest) = n.strip_prefix(&format!("{app_prefix}Frameworks/")) {
                if let Some(item) = top_component(rest) {
                    if (item.ends_with(".framework") || item.ends_with(".dylib"))
                        && !frameworks.contains(&item)
                    {
                        frameworks.push(item);
                    }
                }
            } else if let Some(rest) = n.strip_prefix(&format!("{app_prefix}PlugIns/")) {
                if let Some(item) = top_component(rest) {
                    if item.ends_with(".appex") && !plugins.contains(&item) {
                        plugins.push(item);
                    }
                }
            } else if let Some(rest) = n.strip_prefix(&app_prefix) {
                // .dylib posé directement à la racine du bundle (palier 1).
                if rest.ends_with(".dylib") && !rest.contains('/')
                    && !loose_dylibs.iter().any(|d| d == rest)
                {
                    loose_dylibs.push(rest.to_string());
                }
            }
        }
        frameworks.extend(loose_dylibs);
        frameworks.sort();
        plugins.sort();

        // ── Profil de provisionnement embarqué ──────────────────────────────
        let provision = read_entry(&mut zip, &format!("{app_prefix}embedded.mobileprovision"))
            .and_then(|raw| parse_provision(&raw));

        let payload_apps = names
            .iter()
            .filter(|n| {
                n.strip_prefix("Payload/")
                    .and_then(|r| r.split('/').next())
                    .map(|a| a.ends_with(".app"))
                    .unwrap_or(false)
                    && n.ends_with(".app/Info.plist")
            })
            .count();

        let out = serde_json::json!({
            "name": name,
            "bundleId": s("CFBundleIdentifier").unwrap_or_default(),
            "version": s("CFBundleShortVersionString").unwrap_or_default(),
            "build": s("CFBundleVersion").unwrap_or_default(),
            "minOS": s("MinimumOSVersion").unwrap_or_default(),
            "platformBuild": s("DTPlatformVersion").unwrap_or_default(),
            "executable": executable,
            "deviceFamilies": device_families,
            "archs": archs,
            "encrypted": encrypted,
            "fileSize": file_size,
            "payloadApps": payload_apps,
            "frameworks": frameworks,
            "plugins": plugins,
            "linkedDylibs": linked,
            "provision": provision,
        });
        serde_json::to_string(&out).map_err(|e| format!("sérialisation JSON : {e}"))
    }

    fn top_component(rest: &str) -> Option<String> {
        rest.split('/').next().filter(|c| !c.is_empty()).map(String::from)
    }

    fn read_entry(zip: &mut zip::ZipArchive<File>, name: &str) -> Option<Vec<u8>> {
        let mut entry = zip.by_name(name).ok()?;
        let mut buf = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut buf).ok()?;
        Some(buf)
    }

    // ── Mach-O ──────────────────────────────────────────────────────────────

    struct Macho {
        archs: Vec<String>,
        encrypted: bool,
        dylibs: Vec<String>,
    }

    const FAT_MAGIC: u32 = 0xCAFEBABE;
    const MH_MAGIC_64: u32 = 0xFEEDFACF;
    const MH_MAGIC_32: u32 = 0xFEEDFACE;
    const LC_LOAD_DYLIB: u32 = 0x0C;
    const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
    const LC_ENCRYPTION_INFO: u32 = 0x21;
    const LC_ENCRYPTION_INFO_64: u32 = 0x2C;

    fn rd_u32(b: &[u8], off: usize, be: bool) -> Option<u32> {
        let s = b.get(off..off + 4)?;
        let a = [s[0], s[1], s[2], s[3]];
        Some(if be { u32::from_be_bytes(a) } else { u32::from_le_bytes(a) })
    }

    fn parse_macho(data: &[u8]) -> Macho {
        let mut archs = Vec::new();
        let mut encrypted = false;
        let mut dylibs: Vec<String> = Vec::new();

        // FAT : en-tête big-endian, une table de tranches.
        if rd_u32(data, 0, true) == Some(FAT_MAGIC) {
            let n = rd_u32(data, 4, true).unwrap_or(0).min(32);
            for i in 0..n as usize {
                let base = 8 + i * 20; // fat_arch = 5 × u32
                let Some(cputype) = rd_u32(data, base, true) else { break };
                let cpusub = rd_u32(data, base + 4, true).unwrap_or(0);
                let offset = rd_u32(data, base + 8, true).unwrap_or(0) as usize;
                push_arch(&mut archs, cputype, cpusub);
                if let Some(slice) = data.get(offset..) {
                    let (enc, dl) = parse_thin(slice);
                    encrypted |= enc;
                    merge(&mut dylibs, dl);
                }
            }
            return Macho { archs, encrypted, dylibs };
        }

        // Tranche unique (thin).
        match rd_u32(data, 0, false) {
            Some(MH_MAGIC_64) | Some(MH_MAGIC_32) => {
                if let (Some(cputype), Some(cpusub)) = (rd_u32(data, 4, false), rd_u32(data, 8, false)) {
                    push_arch(&mut archs, cputype, cpusub);
                }
                let (enc, dl) = parse_thin(data);
                encrypted = enc;
                dylibs = dl;
            }
            _ => {}
        }
        Macho { archs, encrypted, dylibs }
    }

    fn merge(into: &mut Vec<String>, more: Vec<String>) {
        for m in more {
            if !into.contains(&m) {
                into.push(m);
            }
        }
    }

    fn push_arch(archs: &mut Vec<String>, cputype: u32, cpusub: u32) {
        let name = arch_name(cputype, cpusub);
        if !name.is_empty() && !archs.contains(&name.to_string()) {
            archs.push(name.to_string());
        }
    }

    fn arch_name(cputype: u32, cpusub: u32) -> &'static str {
        const CPU_ARM64: u32 = 0x0100_000C;
        const CPU_ARM: u32 = 0x0000_000C;
        const CPU_X86_64: u32 = 0x0100_0007;
        const CPU_I386: u32 = 0x0000_0007;
        match cputype {
            CPU_ARM64 => if cpusub & 0x00ff_ffff == 2 { "arm64e" } else { "arm64" },
            CPU_ARM => "armv7",
            CPU_X86_64 => "x86_64",
            CPU_I386 => "i386",
            _ => "",
        }
    }

    /// Parcourt les load commands d'une tranche Mach-O (little-endian, iOS) :
    /// détecte le chiffrement (`cryptid != 0`) et collecte les dylibs liés.
    fn parse_thin(data: &[u8]) -> (bool, Vec<String>) {
        let mut encrypted = false;
        let mut dylibs = Vec::new();

        let magic = match rd_u32(data, 0, false) {
            Some(m) => m,
            None => return (false, dylibs),
        };
        let (ncmds, hdr_size) = match magic {
            MH_MAGIC_64 => (rd_u32(data, 16, false).unwrap_or(0), 32usize),
            MH_MAGIC_32 => (rd_u32(data, 16, false).unwrap_or(0), 28usize),
            _ => return (false, dylibs),
        };

        let mut off = hdr_size;
        for _ in 0..ncmds.min(4096) {
            let cmd = match rd_u32(data, off, false) {
                Some(c) => c,
                None => break,
            };
            let size = rd_u32(data, off + 4, false).unwrap_or(0) as usize;
            if size < 8 || off + size > data.len() {
                break;
            }
            match cmd {
                LC_ENCRYPTION_INFO | LC_ENCRYPTION_INFO_64 => {
                    if rd_u32(data, off + 16, false).unwrap_or(0) != 0 {
                        encrypted = true;
                    }
                }
                LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB => {
                    let name_off = rd_u32(data, off + 8, false).unwrap_or(0) as usize;
                    if name_off >= 8 && off + name_off < off + size {
                        let start = off + name_off;
                        let end = off + size;
                        if let Some(raw) = data.get(start..end) {
                            let s: Vec<u8> = raw.iter().copied().take_while(|&b| b != 0).collect();
                            if let Ok(txt) = String::from_utf8(s) {
                                if !txt.is_empty() && !dylibs.contains(&txt) {
                                    dylibs.push(txt);
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
            off += size;
        }
        (encrypted, dylibs)
    }

    // ── Profil de provisionnement (CMS DER contenant un plist XML) ──────────

    fn parse_provision(raw: &[u8]) -> Option<serde_json::Value> {
        // Le plist est en clair dans le CMS : on l'extrait entre <?xml et
        // </plist>, sans dérouler le PKCS#7.
        let start = find(raw, b"<?xml")?;
        let end = rfind(raw, b"</plist>")? + b"</plist>".len();
        let slice = raw.get(start..end)?;
        let value = plist::Value::from_reader(std::io::Cursor::new(slice)).ok()?;
        let dict = value.as_dictionary()?;

        let s = |k: &str| dict.get(k).and_then(|v| v.as_string()).map(String::from);
        let ent = dict.get("Entitlements").and_then(|v| v.as_dictionary());
        let get_task_allow = ent
            .and_then(|e| e.get("get-task-allow"))
            .and_then(|v| v.as_boolean())
            .unwrap_or(false);
        let app_id = ent
            .and_then(|e| e.get("application-identifier"))
            .and_then(|v| v.as_string())
            .map(String::from)
            .unwrap_or_default();

        let devices = dict
            .get("ProvisionedDevices")
            .and_then(|v| v.as_array())
            .map(|a| a.len())
            .unwrap_or(0);
        let all_devices = dict
            .get("ProvisionsAllDevices")
            .and_then(|v| v.as_boolean())
            .unwrap_or(false);

        // Enterprise : signe tous les appareils. Dev : get-task-allow + appareils
        // listés. Ad hoc : appareils listés sans get-task-allow. App Store : ni
        // l'un ni l'autre.
        let kind = if all_devices {
            "enterprise"
        } else if devices > 0 {
            if get_task_allow { "development" } else { "adhoc" }
        } else {
            "appstore"
        };

        let (expires, days) = match dict.get("ExpirationDate").and_then(|v| v.as_date()) {
            Some(date) => {
                let sys: std::time::SystemTime = date.into();
                let days = sys
                    .duration_since(std::time::SystemTime::now())
                    .map(|d| (d.as_secs() / 86_400) as i64)
                    .unwrap_or(-1);
                (date.to_xml_format(), days)
            }
            None => (String::new(), 0),
        };

        Some(serde_json::json!({
            "name": s("Name").unwrap_or_default(),
            "team": s("TeamName").unwrap_or_default(),
            "appId": app_id,
            "type": kind,
            "getTaskAllow": get_task_allow,
            "devices": devices,
            "expires": expires,
            "daysRemaining": days,
        }))
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack.windows(needle.len()).position(|w| w == needle)
    }

    fn rfind(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack.windows(needle.len()).rposition(|w| w == needle)
    }
}
