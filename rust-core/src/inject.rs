//! Injection de tweaks (`.dylib`) dans un IPA, **avant** signature.
//!
//! Feather/ESign passent par zsign ; ici, pas besoin : `sign_app` signe déjà
//! tout le bundle. Il suffit donc d'injecter avant lui — on extrait l'IPA, on
//! copie le dylib dans `Frameworks/`, on ajoute un `LC_LOAD_DYLIB` à
//! l'exécutable principal, on re-zippe, et `sign_app` signe le dylib avec le
//! reste.
//!
//! L'édition Mach-O suit l'algorithme d'`insert_dylib` en mode « padding » : la
//! commande est écrite dans l'espace libre déjà présent entre la fin des load
//! commands et le premier octet de contenu (première section non nulle). Rien
//! n'est décalé, donc **la taille du fichier ne change pas** et les tranches
//! d'un binaire FAT restent valides. S'il manque de la place, on échoue
//! proprement plutôt que de corrompre le binaire.

#![cfg(feature = "device-account")]

use std::path::{Path, PathBuf};

const LC_LOAD_DYLIB: u32 = 0x0C;
const LC_SEGMENT_64: u32 = 0x19;
const MH_MAGIC_64: u32 = 0xFEED_FACF;
const MH_MAGIC_32: u32 = 0xFEED_FACE;
const FAT_MAGIC: u32 = 0xCAFE_BABE;
const FAT_MAGIC_64: u32 = 0xCAFE_BABF;

/// Injecte chaque dylib dans l'IPA et rend le chemin d'un **nouvel** IPA
/// modifié, prêt à être signé. Si `dylibs` est vide, rend l'IPA d'origine.
pub fn inject_dylibs(ipa_path: &str, dylibs: &[String]) -> Result<String, String> {
    if dylibs.is_empty() {
        return Ok(ipa_path.to_string());
    }

    let work = std::env::temp_dir().join(format!("px-inject-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).map_err(|e| format!("dossier de travail : {e}"))?;

    extract_ipa(Path::new(ipa_path), &work)?;

    let app = find_app_dir(&work)?;
    let exe = main_executable(&app)?;

    let frameworks = app.join("Frameworks");
    std::fs::create_dir_all(&frameworks).map_err(|e| format!("dossier Frameworks : {e}"))?;

    let mut macho = std::fs::read(&exe).map_err(|e| format!("lecture de l'exécutable : {e}"))?;

    for dylib in dylibs {
        let src = Path::new(dylib);
        let name = src
            .file_name()
            .ok_or_else(|| format!("dylib sans nom de fichier : {dylib}"))?
            .to_string_lossy()
            .to_string();
        std::fs::copy(src, frameworks.join(&name))
            .map_err(|e| format!("copie de {name} dans Frameworks : {e}"))?;
        let load_path = format!("@executable_path/Frameworks/{name}");
        add_load_command(&mut macho, &load_path)
            .map_err(|e| format!("injection de {name} : {e}"))?;
    }

    std::fs::write(&exe, &macho).map_err(|e| format!("réécriture de l'exécutable : {e}"))?;
    set_mode(&exe, 0o755)?;

    let out = std::env::temp_dir().join(format!("px-injected-{}.ipa", std::process::id()));
    let _ = std::fs::remove_file(&out);
    zip_payload_dir(&work, &out)?;
    let _ = std::fs::remove_dir_all(&work);

    Ok(out.to_string_lossy().to_string())
}

// ── Localisation du bundle et de l'exécutable ──────────────────────────────

fn find_app_dir(work: &Path) -> Result<PathBuf, String> {
    let payload = work.join("Payload");
    let entries =
        std::fs::read_dir(&payload).map_err(|e| format!("Payload introuvable : {e}"))?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.extension().map(|e| e == "app").unwrap_or(false) {
            return Ok(path);
        }
    }
    Err("aucun .app dans Payload".into())
}

fn main_executable(app: &Path) -> Result<PathBuf, String> {
    // CFBundleExecutable est la source de vérité : le nom du .app ne suffit pas,
    // une app renommée casserait l'hypothèse.
    if let Ok(value) = plist::Value::from_file(app.join("Info.plist")) {
        if let Some(name) = value
            .as_dictionary()
            .and_then(|d| d.get("CFBundleExecutable"))
            .and_then(|v| v.as_string())
        {
            let exe = app.join(name);
            if exe.is_file() {
                return Ok(exe);
            }
        }
    }
    // Repli : le nom du bundle sans « .app ».
    if let Some(stem) = app.file_stem() {
        let exe = app.join(stem);
        if exe.is_file() {
            return Ok(exe);
        }
    }
    Err("exécutable principal introuvable (CFBundleExecutable)".into())
}

// ── Édition Mach-O ─────────────────────────────────────────────────────────

fn read_u32_le(data: &[u8], at: usize) -> Result<u32, String> {
    data.get(at..at + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or_else(|| "Mach-O tronqué".to_string())
}
fn read_u32_be(data: &[u8], at: usize) -> Result<u32, String> {
    data.get(at..at + 4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or_else(|| "en-tête FAT tronqué".to_string())
}
fn write_u32_le(data: &mut [u8], at: usize, v: u32) {
    data[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

/// Ajoute un `LC_LOAD_DYLIB` — thin 64 bits, ou chaque tranche d'un FAT.
fn add_load_command(data: &mut [u8], dylib_path: &str) -> Result<(), String> {
    let magic_le = read_u32_le(data, 0)?;
    let magic_be = read_u32_be(data, 0)?;

    if magic_le == MH_MAGIC_64 {
        return add_thin(data, 0, dylib_path);
    }
    if magic_le == MH_MAGIC_32 {
        return Err("Mach-O 32 bits non supporté (injecte une app arm64)".into());
    }
    if magic_be == FAT_MAGIC || magic_be == FAT_MAGIC_64 {
        let is64 = magic_be == FAT_MAGIC_64;
        let nfat = read_u32_be(data, 4)? as usize;
        let entry = if is64 { 32usize } else { 20usize };
        // fat_arch : cputype(4) cpusubtype(4) offset(…) size(…) align(4)
        let mut offsets = Vec::with_capacity(nfat);
        for i in 0..nfat {
            let base = 8 + i * entry;
            let off = if is64 {
                let hi = read_u32_be(data, base + 8)? as u64;
                let lo = read_u32_be(data, base + 12)? as u64;
                ((hi << 32) | lo) as usize
            } else {
                read_u32_be(data, base + 8)? as usize
            };
            offsets.push(off);
        }
        for off in offsets {
            add_thin(data, off, dylib_path)?;
        }
        return Ok(());
    }
    Err("format non reconnu (pas un Mach-O)".into())
}

fn add_thin(data: &mut [u8], base: usize, dylib_path: &str) -> Result<(), String> {
    if read_u32_le(data, base)? != MH_MAGIC_64 {
        return Err("tranche non 64 bits".into());
    }
    let ncmds = read_u32_le(data, base + 16)?;
    let sizeofcmds = read_u32_le(data, base + 20)? as usize;
    let header = 32usize;
    let lc_end = base + header + sizeofcmds;

    // Plus petit offset de section non nul = début du contenu dans la tranche.
    let mut min_off = usize::MAX;
    let mut cursor = base + header;
    for _ in 0..ncmds {
        let cmd = read_u32_le(data, cursor)?;
        let cmdsize = read_u32_le(data, cursor + 4)? as usize;
        if cmdsize == 0 {
            return Err("load command de taille nulle".into());
        }
        if cmd == LC_SEGMENT_64 {
            let nsects = read_u32_le(data, cursor + 64)? as usize;
            let mut sect = cursor + 72;
            for _ in 0..nsects {
                let off = read_u32_le(data, sect + 48)? as usize;
                if off != 0 {
                    min_off = min_off.min(base + off);
                }
                sect += 80;
            }
        }
        cursor = cursor
            .checked_add(cmdsize)
            .ok_or_else(|| "load commands incohérents".to_string())?;
    }
    if min_off == usize::MAX {
        min_off = lc_end;
    }

    // Nouvelle commande : dylib_command (24 octets fixes) + chemin + NUL,
    // aligné sur 8.
    let path_bytes = dylib_path.as_bytes();
    let cmdsize = (24 + path_bytes.len() + 1 + 7) & !7usize;

    if lc_end + cmdsize > min_off {
        return Err(format!(
            "espace d'en-tête insuffisant ({} libres, {} requis) — binaire non injectable en place",
            min_off.saturating_sub(lc_end),
            cmdsize
        ));
    }
    if lc_end + cmdsize > data.len() {
        return Err("Mach-O tronqué (padding attendu absent)".into());
    }

    write_u32_le(data, lc_end, LC_LOAD_DYLIB);
    write_u32_le(data, lc_end + 4, cmdsize as u32);
    write_u32_le(data, lc_end + 8, 24); // dylib.name.offset
    write_u32_le(data, lc_end + 12, 2); // timestamp
    write_u32_le(data, lc_end + 16, 0x0001_0000); // current_version 1.0.0
    write_u32_le(data, lc_end + 20, 0x0001_0000); // compatibility_version 1.0.0
    data[lc_end + 24..lc_end + 24 + path_bytes.len()].copy_from_slice(path_bytes);
    // Le reste jusqu'à cmdsize est du padding déjà à zéro (NUL de fin compris) ;
    // on le remet à zéro par sécurité.
    for b in data
        .iter_mut()
        .skip(lc_end + 24 + path_bytes.len())
        .take(cmdsize - 24 - path_bytes.len())
    {
        *b = 0;
    }

    write_u32_le(data, base + 16, ncmds + 1);
    write_u32_le(data, base + 20, (sizeofcmds + cmdsize) as u32);
    Ok(())
}

// ── Zip / dézip ────────────────────────────────────────────────────────────

fn extract_ipa(ipa: &Path, dest: &Path) -> Result<(), String> {
    use std::io::Read;
    let file = std::fs::File::open(ipa).map_err(|e| format!("ouverture de l'IPA : {e}"))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("IPA illisible (zip) : {e}"))?;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("entrée {i} illisible : {e}"))?;
        let name = entry.name().to_string();
        // Anti path-traversal : on ignore tout chemin remontant.
        if name.contains("..") {
            continue;
        }
        let out = dest.join(&name);
        let mode = entry.unix_mode();

        if name.ends_with('/') {
            std::fs::create_dir_all(&out).map_err(|e| format!("dossier {name} : {e}"))?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("dossier parent de {name} : {e}"))?;
        }

        // Lien symbolique (S_IFLNK) : le contenu de l'entrée est la cible.
        if let Some(m) = mode {
            if m & 0o170000 == 0o120000 {
                let mut target = String::new();
                entry
                    .read_to_string(&mut target)
                    .map_err(|e| format!("lien {name} : {e}"))?;
                let _ = std::fs::remove_file(&out);
                std::os::unix::fs::symlink(&target, &out)
                    .map_err(|e| format!("symlink {name} : {e}"))?;
                continue;
            }
        }

        let mut buf = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| format!("lecture de {name} : {e}"))?;
        std::fs::write(&out, &buf).map_err(|e| format!("écriture de {name} : {e}"))?;
        if let Some(m) = mode {
            set_mode(&out, m)?;
        }
    }
    Ok(())
}

fn zip_payload_dir(work: &Path, out: &Path) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use zip::write::SimpleFileOptions;

    let payload = work.join("Payload");
    let file = std::fs::File::create(out).map_err(|e| format!("création de l'IPA : {e}"))?;
    let mut writer = zip::ZipWriter::new(file);
    let mut stack = vec![payload];

    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).map_err(|e| format!("lecture de {} : {e}", dir.display()))? {
            let entry = entry.map_err(|e| format!("entrée illisible : {e}"))?;
            let path = entry.path();
            let name = path
                .strip_prefix(work)
                .map_err(|e| format!("chemin hors travail : {e}"))?
                .to_string_lossy()
                .replace('\\', "/");
            let meta = std::fs::symlink_metadata(&path)
                .map_err(|e| format!("métadonnées de {} : {e}", path.display()))?;

            if meta.is_dir() {
                writer
                    .add_directory(format!("{name}/"), SimpleFileOptions::default())
                    .map_err(|e| format!("zip dossier {name} : {e}"))?;
                stack.push(path);
                continue;
            }
            if meta.file_type().is_symlink() {
                let target = std::fs::read_link(&path).map_err(|e| format!("lien {} : {e}", path.display()))?;
                writer
                    .add_symlink(&name, target.to_string_lossy(), SimpleFileOptions::default())
                    .map_err(|e| format!("zip lien {name} : {e}"))?;
                continue;
            }

            let options = SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Stored)
                .unix_permissions(meta.permissions().mode())
                .large_file(true);
            writer
                .start_file(&name, options)
                .map_err(|e| format!("zip fichier {name} : {e}"))?;
            let bytes = std::fs::read(&path).map_err(|e| format!("lecture de {} : {e}", path.display()))?;
            writer
                .write_all(&bytes)
                .map_err(|e| format!("écriture de {name} : {e}"))?;
        }
    }

    writer.finish().map_err(|e| format!("clôture du zip : {e}"))?;
    Ok(())
}

fn set_mode(path: &Path, mode: u32) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
        .map_err(|e| format!("chmod {} : {e}", path.display()))
}
