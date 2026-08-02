//! Injection de tweaks dans un IPA, **avant** signature.
//!
//! Feather/ESign passent par zsign ; ici, pas besoin : `sign_app` signe déjà
//! tout le bundle. Il suffit donc d'injecter avant lui.
//!
//! ── LES TROIS PALIERS ──────────────────────────────────────────────────────
//!
//! **Palier 1 — dylib autonome.** On copie le `.dylib` dans `Frameworks/` et on
//! ajoute un `LC_LOAD_DYLIB` à l'exécutable principal. C'est tout ce qu'il faut
//! pour un tweak sans dépendance (UIKit/Foundation only).
//!
//! **Palier 2 — `.deb` + Substrate.** Un vrai tweak jailbreak arrive en `.deb`
//! (archive `ar` → `data.tar.*` → `Library/MobileSubstrate/DynamicLibraries/`)
//! et dépend de la Substrate (`/usr/lib/libsubstrate.dylib` ou
//! `CydiaSubstrate`). On extrait le dylib du `.deb`, on embarque **ElleKit** (le
//! remplaçant open-source de Substrate) dans `Frameworks/`, et on réécrit la
//! dépendance Substrate du tweak vers ElleKit.
//!
//! **Palier 3 — chaînes de dépendances.** Un tweak peut dépendre d'autres
//! dylibs (`libcolorpicker`, `libprefs`…). On embarque celles qu'on possède
//! (fournies ou tirées du `.deb`), on réécrit leur chemin, et on ajoute un
//! `LC_RPATH` `@executable_path/Frameworks` à l'exécutable — ainsi tout
//! `@rpath/xxx.dylib` se résout dans le bundle.
//!
//! ── POURQUOI `@rpath` ET PAS LE CHEMIN ABSOLU ──────────────────────────────
//! On ne peut pas déposer un fichier à `/usr/lib/...` dans le bac à sable d'une
//! app non jailbreakée : dyld y chercherait sur le vrai système. Il faut donc
//! réécrire la dépendance vers un chemin relatif au bundle. `@rpath/xxx.dylib`
//! est **plus court** que n'importe quel chemin absolu, ce qui permet de le
//! réécrire *en place* sans changer la taille de la commande — l'édition Mach-O
//! reste sans décalage, comme l'ajout de commande (algorithme « padding »
//! d'`insert_dylib` : on écrit dans l'espace libre entre la fin des load
//! commands et le premier octet de contenu ; la taille du fichier ne bouge pas).

#![cfg(feature = "device-account")]

use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};

const LC_LOAD_DYLIB: u32 = 0x0C;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001F;
const LC_RPATH: u32 = 0x8000_001C;
const LC_SEGMENT_64: u32 = 0x19;
const MH_MAGIC_64: u32 = 0xFEED_FACF;
const MH_MAGIC_32: u32 = 0xFEED_FACE;
const FAT_MAGIC: u32 = 0xCAFE_BABE;
const FAT_MAGIC_64: u32 = 0xCAFE_BABF;

/// Un tweak reçoit un `LC_LOAD_DYLIB` dans l'exécutable ; une dépendance est
/// seulement embarquée et référencée par le tweak qui la charge.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Tweak,
    Dependency,
}

/// Options d'injection, façon Feather.
///
/// - `path_prefix` : le préfixe du `LC_LOAD_DYLIB` — `@executable_path`,
///   `@loader_path` ou `@rpath`. `@executable_path` par défaut, le plus sûr.
/// - `folder` : le dossier où poser les dylibs dans le bundle (`Frameworks`).
/// - `into_extensions` : injecter aussi dans chaque extension (`PlugIns/*.appex`),
///   en visant le dossier partagé du bundle par un chemin relatif.
pub struct InjectOptions {
    pub path_prefix: String,
    pub folder: String,
    pub into_extensions: bool,
}

impl Default for InjectOptions {
    fn default() -> Self {
        Self {
            path_prefix: "@executable_path".to_string(),
            folder: "Frameworks".to_string(),
            into_extensions: false,
        }
    }
}

impl InjectOptions {
    /// Nettoie les entrées : préfixe connu, dossier non vide sans slash parasite.
    fn normalized(mut self) -> Self {
        let p = self.path_prefix.trim();
        self.path_prefix = match p {
            "@rpath" | "@loader_path" | "@executable_path" => p.to_string(),
            _ => "@executable_path".to_string(),
        };
        let f = self.folder.trim().trim_matches('/');
        self.folder = if f.is_empty() { "Frameworks".to_string() } else { f.to_string() };
        self
    }

    /// Chemin qui, depuis un binaire donné, atteint le dossier d'injection.
    /// Depuis l'exécutable principal : `@executable_path/<folder>`. Depuis une
    /// extension (`PlugIns/X.appex/`), il faut remonter de deux crans.
    fn reach(&self, is_extension: bool) -> String {
        let up = if is_extension { "/../.." } else { "" };
        format!("@executable_path{up}/{}", self.folder)
    }

    /// Chemin de chargement écrit dans le `LC_LOAD_DYLIB` pour `name`.
    fn load_path(&self, name: &str, is_extension: bool) -> String {
        if self.path_prefix == "@rpath" {
            format!("@rpath/{name}")
        } else {
            let up = if is_extension { "/../.." } else { "" };
            format!("{}{up}/{}/{}", self.path_prefix, self.folder, name)
        }
    }
}

/// Injecte chaque entrée dans l'IPA et rend le chemin d'un **nouvel** IPA
/// modifié, prêt à être signé. Chaque entrée est un `.dylib` (palier 1) ou un
/// `.deb` (palier 2/3). Si `inputs` est vide, rend l'IPA d'origine.
pub fn inject_dylibs(
    ipa_path: &str,
    inputs: &[String],
    opts: &InjectOptions,
) -> Result<String, String> {
    if inputs.is_empty() {
        return Ok(ipa_path.to_string());
    }

    // Options normalisées (préfixe connu, dossier propre).
    let opts = InjectOptions {
        path_prefix: opts.path_prefix.clone(),
        folder: opts.folder.clone(),
        into_extensions: opts.into_extensions,
    }
    .normalized();

    let work = std::env::temp_dir().join(format!("px-inject-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).map_err(|e| format!("dossier de travail : {e}"))?;

    // 1. Rassembler les dylibs : dépaqueter les .deb, laisser passer les .dylib.
    //    `substrate` retient le nom de fichier du fournisseur Substrate embarqué
    //    (ElleKit, ou une vraie libsubstrate fournie), pour y router les
    //    dépendances Substrate des tweaks.
    let deb_out = work.join("__deb");
    let mut libs: Vec<(PathBuf, Kind)> = Vec::new();
    let mut substrate: Option<String> = None;

    for input in inputs {
        let path = Path::new(input);
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();

        if ext == "deb" {
            for (p, kind) in extract_deb(path, &deb_out)? {
                classify(p, kind, &mut libs, &mut substrate);
            }
        } else {
            // Tout ce qui n'est pas .deb est traité comme un dylib fourni.
            classify(path.to_path_buf(), Kind::Tweak, &mut libs, &mut substrate);
        }
    }

    if libs.is_empty() {
        return Err("aucun dylib trouvé dans ce qui a été fourni".into());
    }

    // 2. Extraire l'IPA et préparer le bundle.
    extract_ipa(Path::new(ipa_path), &work)?;
    let app = find_app_dir(&work)?;
    let exe = main_executable(&app)?;
    let frameworks = app.join(&opts.folder);
    std::fs::create_dir_all(&frameworks)
        .map_err(|e| format!("dossier {} : {e}", opts.folder))?;

    // 3. Copier chaque dylib dans Frameworks/ (dédupliqué par nom de fichier),
    //    en retenant l'ordre des tweaks pour les LC_LOAD_DYLIB.
    let mut bundled: HashSet<String> = HashSet::new();
    let mut tweak_names: Vec<String> = Vec::new();

    for (src, kind) in &libs {
        let name = src
            .file_name()
            .ok_or_else(|| format!("dylib sans nom : {}", src.display()))?
            .to_string_lossy()
            .to_string();

        if bundled.insert(name.clone()) {
            std::fs::copy(src, frameworks.join(&name))
                .map_err(|e| format!("copie de {name} dans Frameworks : {e}"))?;
            set_mode(&frameworks.join(&name), 0o755)?;
        }
        if *kind == Kind::Tweak && !tweak_names.contains(&name) {
            tweak_names.push(name);
        }
    }

    // 3b. Garde-fou : un tweak qui dépend de la Substrate sans ElleKit fourni
    //     planterait au chargement (chemin `/usr/lib/...` injoignable dans le
    //     bac à sable). On le dit clairement plutôt que de livrer un binaire qui
    //     crashe à l'ouverture.
    if substrate.is_none() {
        for name in &bundled {
            let macho = std::fs::read(frameworks.join(name))
                .map_err(|e| format!("lecture de {name} : {e}"))?;
            if references_substrate(&macho)? {
                let _ = std::fs::remove_dir_all(&work);
                return Err(format!(
                    "Le tweak « {name} » dépend de la Substrate, mais ElleKit n'a pas été fourni. \
                     Ajoute ElleKit (libellekit.dylib, ou le .deb d'ElleKit) à la liste des tweaks."
                ));
            }
        }
    }

    // 4. Table de réécriture : chaque dylib embarqué devient joignable en
    //    `@rpath/<nom>`, et les alias Substrate pointent vers ElleKit.
    let mut rename: HashMap<String, String> = HashMap::new();
    for name in &bundled {
        rename.insert(name.clone(), format!("@rpath/{name}"));
    }
    if let Some(elle) = &substrate {
        for alias in [
            "libsubstrate.dylib",
            "libsubstrate.0.dylib",
            "CydiaSubstrate",
            "libSubstrate.dylib",
        ] {
            rename.insert(alias.to_string(), format!("@rpath/{elle}"));
        }
    }

    // 5. Réécrire les dépendances *à l'intérieur* de chaque dylib embarqué :
    //    Substrate → ElleKit, et toute dépendance qu'on embarque → @rpath.
    let mut used_rpath = false;
    for name in &bundled {
        let file = frameworks.join(name);
        let mut macho =
            std::fs::read(&file).map_err(|e| format!("lecture de {name} : {e}"))?;
        if rewrite_deps(&mut macho, &rename)? {
            std::fs::write(&file, &macho).map_err(|e| format!("réécriture de {name} : {e}"))?;
            set_mode(&file, 0o755)?;
            used_rpath = true;
        }
    }

    // 6. Câblage : un LC_LOAD_DYLIB par tweak dans l'exécutable principal, et
    //    dans chaque extension si demandé. Un LC_RPATH est ajouté quand le
    //    préfixe choisi est @rpath, ou quand des dépendances passent par @rpath.
    let need_rpath = used_rpath || opts.path_prefix == "@rpath";
    wire_binary(&exe, &tweak_names, &opts, false, need_rpath)
        .map_err(|e| format!("exécutable principal : {e}"))?;

    if opts.into_extensions {
        for appex_exe in extension_executables(&app) {
            // Une extension qui refuse le patch ne doit pas faire échouer toute
            // l'installation — on l'ignore avec une trace.
            if let Err(e) = wire_binary(&appex_exe, &tweak_names, &opts, true, need_rpath) {
                tracing::warn!("extension {} non patchée : {e}", appex_exe.display());
            }
        }
    }

    // 7. Re-zipper.
    let out = std::env::temp_dir().join(format!("px-injected-{}.ipa", std::process::id()));
    let _ = std::fs::remove_file(&out);
    zip_payload_dir(&work, &out)?;
    let _ = std::fs::remove_dir_all(&work);

    Ok(out.to_string_lossy().to_string())
}

/// Range un dylib dans la bonne liste et repère un éventuel fournisseur
/// Substrate (ElleKit ou vraie libsubstrate) — celui-ci ne reçoit pas de
/// LC_LOAD_DYLIB propre : c'est le tweak qui le tire.
fn classify(
    path: PathBuf,
    kind: Kind,
    libs: &mut Vec<(PathBuf, Kind)>,
    substrate: &mut Option<String>,
) {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let lower = name.to_lowercase();

    if lower.contains("ellekit")
        || lower == "cydiasubstrate"
        || lower.starts_with("libsubstrate")
    {
        if substrate.is_none() {
            *substrate = Some(name);
        }
        libs.push((path, Kind::Dependency));
    } else {
        libs.push((path, kind));
    }
}

/// Ajoute les `LC_LOAD_DYLIB` (un par tweak) et, si besoin, le `LC_RPATH` vers
/// le dossier d'injection, dans le binaire donné (exécutable ou extension).
fn wire_binary(
    exe: &Path,
    tweak_names: &[String],
    opts: &InjectOptions,
    is_extension: bool,
    need_rpath: bool,
) -> Result<(), String> {
    let mut macho = std::fs::read(exe).map_err(|e| format!("lecture : {e}"))?;
    for name in tweak_names {
        let load = opts.load_path(name, is_extension);
        add_load_command(&mut macho, &load, LC_LOAD_DYLIB)
            .map_err(|e| format!("injection de {name} : {e}"))?;
    }
    if need_rpath {
        add_load_command(&mut macho, &opts.reach(is_extension), LC_RPATH)
            .map_err(|e| format!("ajout du rpath : {e}"))?;
    }
    std::fs::write(exe, &macho).map_err(|e| format!("réécriture : {e}"))?;
    set_mode(exe, 0o755)
}

/// Exécutables des extensions du bundle (`PlugIns/*.appex`).
fn extension_executables(app: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(app.join("PlugIns")) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "appex").unwrap_or(false) {
            if let Ok(exe) = main_executable(&path) {
                out.push(exe);
            }
        }
    }
    out
}

// ── Extraction d'un .deb ───────────────────────────────────────────────────

/// Dépaquète un `.deb` et rend les dylibs qu'il contient. Les dylibs sous
/// `MobileSubstrate/DynamicLibraries` sont des tweaks ; les autres, des
/// dépendances.
fn extract_deb(deb: &Path, dest: &Path) -> Result<Vec<(PathBuf, Kind)>, String> {
    let bytes = std::fs::read(deb).map_err(|e| format!("lecture du .deb : {e}"))?;
    if !bytes.starts_with(b"!<arch>\n") {
        return Err("ce n'est pas un .deb (signature ar absente)".into());
    }

    // Archive ar : en-têtes de 60 octets, données alignées sur un octet pair.
    let mut pos = 8usize;
    let mut data_tar: Option<(Vec<u8>, String)> = None;
    while pos + 60 <= bytes.len() {
        let header = &bytes[pos..pos + 60];
        let name = std::str::from_utf8(&header[0..16])
            .map_err(|_| "en-tête ar illisible".to_string())?
            .trim_end()
            .trim_end_matches('/')
            .to_string();
        let size: usize = std::str::from_utf8(&header[48..58])
            .map_err(|_| "taille ar illisible".to_string())?
            .trim()
            .parse()
            .map_err(|_| "taille ar invalide".to_string())?;
        let start = pos + 60;
        let end = start
            .checked_add(size)
            .ok_or_else(|| "membre ar hors limites".to_string())?;
        if end > bytes.len() {
            return Err("membre ar tronqué".into());
        }
        if name.starts_with("data.tar") {
            data_tar = Some((bytes[start..end].to_vec(), name));
            break;
        }
        pos = end + (size & 1);
    }

    let (compressed, name) =
        data_tar.ok_or_else(|| "pas de data.tar dans le .deb".to_string())?;
    let tar_bytes = decompress(&compressed, &name)?;

    std::fs::create_dir_all(dest).map_err(|e| format!("dossier .deb : {e}"))?;
    let mut found: Vec<(PathBuf, Kind)> = Vec::new();
    let mut archive = tar::Archive::new(Cursor::new(tar_bytes));
    for entry in archive
        .entries()
        .map_err(|e| format!("data.tar illisible : {e}"))?
    {
        let mut entry = entry.map_err(|e| format!("entrée data.tar illisible : {e}"))?;
        let path = entry
            .path()
            .map_err(|e| format!("chemin data.tar illisible : {e}"))?
            .to_string_lossy()
            .to_string();

        if !path.to_lowercase().ends_with(".dylib") {
            continue;
        }
        let base = path.rsplit('/').next().unwrap_or(&path).to_string();
        if base.is_empty() {
            continue;
        }
        let kind = if path.contains("MobileSubstrate/DynamicLibraries")
            || path.contains("TweakInject")
        {
            Kind::Tweak
        } else {
            Kind::Dependency
        };

        let mut buf = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| format!("lecture de {base} : {e}"))?;
        let out = dest.join(&base);
        std::fs::write(&out, &buf).map_err(|e| format!("écriture de {base} : {e}"))?;
        found.push((out, kind));
    }

    if found.is_empty() {
        return Err("aucun .dylib dans ce .deb".into());
    }
    Ok(found)
}

/// Décompresse `data.tar.*` selon son extension. Décodeurs pur Rust, pour que
/// la cross-compilation iOS reste sans dépendance C.
fn decompress(data: &[u8], name: &str) -> Result<Vec<u8>, String> {
    let lower = name.to_lowercase();
    if lower.ends_with(".tar") {
        return Ok(data.to_vec());
    }
    if lower.ends_with(".gz") {
        use flate2::read::GzDecoder;
        let mut out = Vec::new();
        GzDecoder::new(data)
            .read_to_end(&mut out)
            .map_err(|e| format!("gzip : {e}"))?;
        return Ok(out);
    }
    if lower.ends_with(".xz") {
        let mut out = Vec::new();
        lzma_rs::xz_decompress(&mut Cursor::new(data), &mut out)
            .map_err(|e| format!("xz : {e}"))?;
        return Ok(out);
    }
    if lower.ends_with(".lzma") {
        let mut out = Vec::new();
        lzma_rs::lzma_decompress(&mut Cursor::new(data), &mut out)
            .map_err(|e| format!("lzma : {e}"))?;
        return Ok(out);
    }
    if lower.ends_with(".zst") {
        let mut decoder = ruzstd::StreamingDecoder::new(Cursor::new(data))
            .map_err(|e| format!("zstd : {e}"))?;
        let mut out = Vec::new();
        decoder
            .read_to_end(&mut out)
            .map_err(|e| format!("zstd : {e}"))?;
        return Ok(out);
    }
    Err(format!(
        "compression de {name} non gérée (gz, xz, lzma, zst supportés)"
    ))
}

// ── Localisation du bundle et de l'exécutable ──────────────────────────────

pub(crate) fn find_app_dir(work: &Path) -> Result<PathBuf, String> {
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

/// Applique `f` à la tranche thin 64 bits, ou à chaque tranche arm64 d'un FAT.
/// Les tranches 32 bits d'un FAT sont ignorées (l'app tourne en arm64) ; un
/// binaire thin 32 bits est refusé.
fn foreach_slice<F>(data: &mut [u8], mut f: F) -> Result<(), String>
where
    F: FnMut(&mut [u8], usize) -> Result<(), String>,
{
    let magic_le = read_u32_le(data, 0)?;
    let magic_be = read_u32_be(data, 0)?;

    if magic_le == MH_MAGIC_64 {
        return f(data, 0);
    }
    if magic_le == MH_MAGIC_32 {
        return Err("Mach-O 32 bits non supporté (fournis de l'arm64)".into());
    }
    if magic_be == FAT_MAGIC || magic_be == FAT_MAGIC_64 {
        let is64 = magic_be == FAT_MAGIC_64;
        let nfat = read_u32_be(data, 4)? as usize;
        let entry = if is64 { 32usize } else { 20usize };
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
            // Ne toucher que les tranches 64 bits ; ignorer une éventuelle
            // tranche armv7.
            if read_u32_le(data, off)? == MH_MAGIC_64 {
                f(data, off)?;
            }
        }
        return Ok(());
    }
    Err("format non reconnu (pas un Mach-O)".into())
}

/// Ajoute une load command (`LC_LOAD_DYLIB` ou `LC_RPATH`) portant `payload`.
fn add_load_command(data: &mut [u8], payload: &str, kind: u32) -> Result<(), String> {
    foreach_slice(data, |d, base| add_command_thin(d, base, payload, kind))
}

fn add_command_thin(data: &mut [u8], base: usize, payload: &str, kind: u32) -> Result<(), String> {
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

    // Décalage de la chaîne dans la commande : 24 pour dylib_command
    // (name.offset après timestamp + versions), 12 pour rpath_command.
    let str_off = match kind {
        LC_LOAD_DYLIB => 24usize,
        LC_RPATH => 12usize,
        _ => return Err("type de load command non géré".into()),
    };
    let path_bytes = payload.as_bytes();
    let cmdsize = (str_off + path_bytes.len() + 1 + 7) & !7usize;

    if lc_end + cmdsize > min_off {
        return Err(format!(
            "espace d'en-tête insuffisant ({} libres, {} requis) — binaire non éditable en place",
            min_off.saturating_sub(lc_end),
            cmdsize
        ));
    }
    if lc_end + cmdsize > data.len() {
        return Err("Mach-O tronqué (padding attendu absent)".into());
    }

    write_u32_le(data, lc_end, kind);
    write_u32_le(data, lc_end + 4, cmdsize as u32);
    write_u32_le(data, lc_end + 8, str_off as u32);
    if kind == LC_LOAD_DYLIB {
        write_u32_le(data, lc_end + 12, 2); // timestamp
        write_u32_le(data, lc_end + 16, 0x0001_0000); // current_version 1.0.0
        write_u32_le(data, lc_end + 20, 0x0001_0000); // compatibility_version 1.0.0
    }
    data[lc_end + str_off..lc_end + str_off + path_bytes.len()].copy_from_slice(path_bytes);
    for b in data
        .iter_mut()
        .skip(lc_end + str_off + path_bytes.len())
        .take(cmdsize - str_off - path_bytes.len())
    {
        *b = 0;
    }

    write_u32_le(data, base + 16, ncmds + 1);
    write_u32_le(data, base + 20, (sizeofcmds + cmdsize) as u32);
    Ok(())
}

/// Réécrit, dans chaque tranche, les dépendances dont le nom de fichier figure
/// dans `rename`. La cible (`@rpath/...`) étant plus courte que tout chemin
/// absolu, elle tient dans la place existante — on écrase et on complète de
/// NUL, sans changer `cmdsize`. Rend `true` si au moins une réécriture a eu
/// lieu.
fn rewrite_deps(data: &mut [u8], rename: &HashMap<String, String>) -> Result<bool, String> {
    let mut changed = false;
    foreach_slice(data, |d, base| {
        if rewrite_deps_thin(d, base, rename)? {
            changed = true;
        }
        Ok(())
    })?;
    Ok(changed)
}

/// Vrai si une tranche référence la Substrate par son chemin absolu habituel.
fn references_substrate(data: &[u8]) -> Result<bool, String> {
    // `foreach_slice` prend un `&mut` ; ici on ne modifie rien, mais on réutilise
    // sa logique de parcours FAT/thin sur une copie de travail.
    let mut buf = data.to_vec();
    let mut found = false;
    foreach_slice(&mut buf, |d, base| {
        let ncmds = read_u32_le(d, base + 16)?;
        let mut cursor = base + 32;
        for _ in 0..ncmds {
            let cmd = read_u32_le(d, cursor)?;
            let cmdsize = read_u32_le(d, cursor + 4)? as usize;
            if cmdsize == 0 {
                return Err("load command de taille nulle".into());
            }
            if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB {
                let name_off = read_u32_le(d, cursor + 8)? as usize;
                if name_off < cmdsize {
                    let start = cursor + name_off;
                    let limit = cursor + cmdsize;
                    let mut end = start;
                    while end < limit && d.get(end).copied().unwrap_or(0) != 0 {
                        end += 1;
                    }
                    let dep = String::from_utf8_lossy(&d[start..end]);
                    let file = dep.rsplit('/').next().unwrap_or(&dep).to_lowercase();
                    if file.starts_with("libsubstrate") || file == "cydiasubstrate" {
                        found = true;
                    }
                }
            }
            cursor = cursor
                .checked_add(cmdsize)
                .ok_or_else(|| "load commands incohérents".to_string())?;
        }
        Ok(())
    })?;
    Ok(found)
}

fn rewrite_deps_thin(
    data: &mut [u8],
    base: usize,
    rename: &HashMap<String, String>,
) -> Result<bool, String> {
    let ncmds = read_u32_le(data, base + 16)?;
    let mut changed = false;
    let mut cursor = base + 32;

    for _ in 0..ncmds {
        let cmd = read_u32_le(data, cursor)?;
        let cmdsize = read_u32_le(data, cursor + 4)? as usize;
        if cmdsize == 0 {
            return Err("load command de taille nulle".into());
        }

        if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB {
            let name_off = read_u32_le(data, cursor + 8)? as usize;
            if name_off < cmdsize {
                let start = cursor + name_off;
                let limit = cursor + cmdsize;
                let mut end = start;
                while end < limit && data.get(end).copied().unwrap_or(0) != 0 {
                    end += 1;
                }
                let current = String::from_utf8_lossy(&data[start..end]).to_string();
                let file = current.rsplit('/').next().unwrap_or(&current).to_string();

                if let Some(target) = rename.get(&file) {
                    let max = limit - start; // place disponible pour chaîne + NUL
                    if target.as_str() != current && target.len() + 1 <= max {
                        let tb = target.as_bytes();
                        data[start..start + tb.len()].copy_from_slice(tb);
                        for b in data.iter_mut().take(limit).skip(start + tb.len()) {
                            *b = 0;
                        }
                        changed = true;
                    }
                }
            }
        }

        cursor = cursor
            .checked_add(cmdsize)
            .ok_or_else(|| "load commands incohérents".to_string())?;
    }
    Ok(changed)
}

// ── Zip / dézip ────────────────────────────────────────────────────────────

pub(crate) fn extract_ipa(ipa: &Path, dest: &Path) -> Result<(), String> {
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
