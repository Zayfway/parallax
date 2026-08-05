//! Moteur mémoire typé exposé en C pour l'overlay UIKit (PrismOverlay.m).
//! Types : i8/i16/i32/i64, u8/u16/u32/u64, f32, f64. Entrées décimales ou hex
//! (`0x…`). Scan, affinage (=/▲/▼/≈), lecture, écriture, gel (freeze).

use crate::vm;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;
use std::time::Duration;

const MAX_REGION: u64 = 512 * 1024 * 1024;
const MAX_CANDS: usize = 400_000;
const CHUNK: usize = 8 * 1024 * 1024;

#[derive(Copy, Clone, PartialEq)]
enum Ty {
    I8, I16, I32, I64, U8, U16, U32, U64, F32, F64,
}

impl Ty {
    fn from_u8(n: u8) -> Ty {
        match n {
            0 => Ty::I8, 1 => Ty::I16, 2 => Ty::I32, 3 => Ty::I64,
            4 => Ty::U8, 5 => Ty::U16, 6 => Ty::U32, 7 => Ty::U64,
            8 => Ty::F32, 9 => Ty::F64, _ => Ty::I32,
        }
    }
    fn width(self) -> usize {
        match self {
            Ty::I8 | Ty::U8 => 1,
            Ty::I16 | Ty::U16 => 2,
            Ty::I32 | Ty::U32 | Ty::F32 => 4,
            Ty::I64 | Ty::U64 | Ty::F64 => 8,
        }
    }
    /// Octets little-endian de la valeur saisie (décimal ou 0x hex).
    fn parse(self, s: &str) -> Option<Vec<u8>> {
        let s = s.trim();
        match self {
            Ty::F32 => Some(s.parse::<f32>().ok()?.to_le_bytes().to_vec()),
            Ty::F64 => Some(s.parse::<f64>().ok()?.to_le_bytes().to_vec()),
            _ => {
                let v: i128 = if let Some(h) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                    i128::from_str_radix(h, 16).ok()?
                } else if let Some(h) = s.strip_prefix("-0x").or_else(|| s.strip_prefix("-0X")) {
                    -i128::from_str_radix(h, 16).ok()?
                } else {
                    s.parse::<i128>().ok()?
                };
                Some(v.to_le_bytes()[..self.width()].to_vec())
            }
        }
    }
    /// Valeur numérique (pour comparer ▲▼≈).
    fn num(self, b: &[u8]) -> f64 {
        macro_rules! g { ($t:ty, $n:expr) => {{ let mut a=[0u8;$n]; a.copy_from_slice(&b[..$n]); <$t>::from_le_bytes(a) as f64 }}; }
        match self {
            Ty::I8 => b[0] as i8 as f64,
            Ty::U8 => b[0] as f64,
            Ty::I16 => g!(i16, 2),
            Ty::U16 => g!(u16, 2),
            Ty::I32 => g!(i32, 4),
            Ty::U32 => g!(u32, 4),
            Ty::I64 => g!(i64, 8),
            Ty::U64 => g!(u64, 8),
            Ty::F32 => g!(f32, 4),
            Ty::F64 => g!(f64, 8),
        }
    }
    /// Représentation lisible de la valeur à afficher.
    fn fmt(self, b: &[u8]) -> String {
        macro_rules! g { ($t:ty, $n:expr) => {{ let mut a=[0u8;$n]; a.copy_from_slice(&b[..$n]); <$t>::from_le_bytes(a) }}; }
        match self {
            Ty::I8 => format!("{}", b[0] as i8),
            Ty::U8 => format!("{}", b[0]),
            Ty::I16 => format!("{}", g!(i16, 2)),
            Ty::U16 => format!("{}", g!(u16, 2)),
            Ty::I32 => format!("{}", g!(i32, 4)),
            Ty::U32 => format!("{}", g!(u32, 4)),
            Ty::I64 => format!("{}", g!(i64, 8)),
            Ty::U64 => format!("{}", g!(u64, 8)),
            Ty::F32 => format!("{}", g!(f32, 4)),
            Ty::F64 => format!("{}", g!(f64, 8)),
        }
    }
}

#[derive(Default)]
struct TState {
    cands: Vec<u64>,
    last: Vec<f64>,
    ty: u8,
}

static STATE: Mutex<TState> = Mutex::new(TState { cands: Vec::new(), last: Vec::new(), ty: 2 });
// (addr, ty, bytes) — le thread de gel réécrit périodiquement.
static FREEZE: Mutex<Vec<(u64, u8, Vec<u8>)>> = Mutex::new(Vec::new());

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}
fn cstr_in(p: *const c_char) -> String {
    if p.is_null() { return String::new(); }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}
fn cjson(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}
fn sample_json(st: &TState) -> String {
    let sample: Vec<String> = st.cands.iter().take(200).map(|a| a.to_string()).collect();
    format!("{{\"count\":{},\"sample\":[{}]}}", st.cands.len(), sample.join(","))
}

#[no_mangle]
pub extern "C" fn prism_eng_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) };
    }
}

/// JSON `[{addr,size,prot,tag}]`.
#[no_mangle]
pub extern "C" fn prism_eng_regions() -> *mut c_char {
    let items: Vec<String> = vm::regions()
        .iter()
        .map(|r| format!("{{\"addr\":{},\"size\":{},\"prot\":{},\"tag\":{}}}", r.addr, r.size, r.prot, r.tag))
        .collect();
    cjson(format!("[{}]", items.join(",")))
}

/// Première recherche. `ty` = type, `value` = C-string. JSON `{count,sample}`.
#[no_mangle]
pub extern "C" fn prism_eng_scan(ty: u8, value: *const c_char) -> *mut c_char {
    let t = Ty::from_u8(ty);
    let Some(needle) = t.parse(&cstr_in(value)) else {
        return cjson("{\"count\":0,\"sample\":[],\"error\":\"valeur invalide\"}".into());
    };
    let w = t.width();
    let mut st = lock(&STATE);
    st.ty = ty;
    st.cands.clear();
    st.last.clear();
    let mut buf = vec![0u8; CHUNK];
    'regions: for (base, size) in vm::scan_regions() {
        if size > MAX_REGION {
            continue;
        }
        let mut off: u64 = 0;
        while off < size {
            let this = std::cmp::min(CHUNK as u64, size - off) as usize;
            let got = match vm::read_mem(base + off, &mut buf[..this]) {
                Some(n) => n,
                None => break,
            };
            let mut i = 0usize;
            while i + w <= got {
                if &buf[i..i + w] == needle.as_slice() {
                    st.cands.push(base + off + i as u64);
                    st.last.push(t.num(&needle));
                    if st.cands.len() >= MAX_CANDS {
                        break 'regions;
                    }
                }
                i += w; // alignement = largeur du type
            }
            off += this as u64;
        }
    }
    let out = sample_json(&st);
    cjson(out)
}

/// Une passe d'affinage. `op` = 0 EQ, 1 ▲, 2 ▼, 3 ≈.
#[no_mangle]
pub extern "C" fn prism_eng_refine(ty: u8, op: u8, value: *const c_char) -> *mut c_char {
    let t = Ty::from_u8(ty);
    let needle = t.parse(&cstr_in(value));
    let w = t.width();
    let mut st = lock(&STATE);
    let mut ka = Vec::new();
    let mut kl = Vec::new();
    let mut buf = vec![0u8; w];
    for idx in 0..st.cands.len() {
        let addr = st.cands[idx];
        if vm::read_mem(addr, &mut buf).unwrap_or(0) < w {
            continue;
        }
        let cur = t.num(&buf);
        let prev = st.last.get(idx).copied().unwrap_or(cur);
        let ok = match op {
            0 => needle.as_ref().map_or(false, |n| buf.as_slice() == n.as_slice()),
            1 => cur > prev,
            2 => cur < prev,
            3 => (cur - prev).abs() < f64::EPSILON, // inchangé
            4 => (cur - prev).abs() >= f64::EPSILON, // changé (recherche floue)
            _ => false,
        };
        if ok {
            ka.push(addr);
            kl.push(cur);
        }
    }
    st.cands = ka;
    st.last = kl;
    let out = sample_json(&st);
    cjson(out)
}

/// Recherche floue (valeur inconnue) : capture TOUS les slots alignés du type
/// avec leur valeur courante. On affine ensuite par ▲/▼/≈/≠ sans saisir de
/// valeur. Plafonné en mémoire ; on note si tronqué.
#[no_mangle]
pub extern "C" fn prism_eng_fuzzy_start(ty: u8) -> *mut c_char {
    const FUZZY_CAP: usize = 2_000_000;
    let t = Ty::from_u8(ty);
    let w = t.width();
    let mut st = lock(&STATE);
    st.ty = ty;
    st.cands.clear();
    st.last.clear();
    let mut buf = vec![0u8; CHUNK];
    'regions: for (base, size) in vm::scan_regions() {
        if size > MAX_REGION {
            continue;
        }
        let mut off: u64 = 0;
        while off < size {
            let this = std::cmp::min(CHUNK as u64, size - off) as usize;
            let got = match vm::read_mem(base + off, &mut buf[..this]) {
                Some(n) => n,
                None => break,
            };
            let mut i = 0usize;
            while i + w <= got {
                st.cands.push(base + off + i as u64);
                st.last.push(t.num(&buf[i..i + w]));
                if st.cands.len() >= FUZZY_CAP {
                    break 'regions;
                }
                i += w;
            }
            off += this as u64;
        }
    }
    let out = sample_json(&st);
    cjson(out)
}

/// Lit la valeur typée à `addr`, formatée. Chaîne vide si échec.
#[no_mangle]
pub extern "C" fn prism_eng_read(ty: u8, addr: u64) -> *mut c_char {
    let t = Ty::from_u8(ty);
    let mut buf = vec![0u8; t.width()];
    if vm::read_mem(addr, &mut buf).unwrap_or(0) < t.width() {
        return cjson(String::new());
    }
    cjson(t.fmt(&buf))
}

/// Écrit la valeur typée. 0 = ok, -1 = échec.
#[no_mangle]
pub extern "C" fn prism_eng_write(ty: u8, addr: u64, value: *const c_char) -> c_int {
    let t = Ty::from_u8(ty);
    match t.parse(&cstr_in(value)) {
        Some(bytes) if vm::write_mem(addr, &bytes) => 0,
        _ => -1,
    }
}

/// Mode auto : écrit `value` sur TOUS les candidats. Renvoie le nombre écrit.
#[no_mangle]
pub extern "C" fn prism_eng_write_all(ty: u8, value: *const c_char) -> c_int {
    let t = Ty::from_u8(ty);
    let Some(bytes) = t.parse(&cstr_in(value)) else { return -1; };
    let cands: Vec<u64> = { lock(&STATE).cands.iter().take(200_000).copied().collect() };
    let mut n = 0;
    for addr in cands {
        if vm::write_mem(addr, &bytes) {
            n += 1;
        }
    }
    n as c_int
}

/// Mode auto : fige TOUS les candidats à `value`. Renvoie le nombre figé.
#[no_mangle]
pub extern "C" fn prism_eng_freeze_all(ty: u8, value: *const c_char) -> c_int {
    let t = Ty::from_u8(ty);
    let Some(bytes) = t.parse(&cstr_in(value)) else { return -1; };
    let cands: Vec<u64> = { lock(&STATE).cands.iter().take(50_000).copied().collect() };
    let mut f = lock(&FREEZE);
    let mut n = 0;
    for addr in cands {
        f.retain(|(a, _, _)| *a != addr);
        f.push((addr, ty, bytes.clone()));
        n += 1;
    }
    n as c_int
}

// ── Gel ─────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn prism_eng_freeze_add(ty: u8, addr: u64, value: *const c_char) {
    let t = Ty::from_u8(ty);
    if let Some(bytes) = t.parse(&cstr_in(value)) {
        let mut f = lock(&FREEZE);
        f.retain(|(a, _, _)| *a != addr);
        f.push((addr, ty, bytes));
    }
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_remove(addr: u64) {
    lock(&FREEZE).retain(|(a, _, _)| *a != addr);
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_clear() {
    lock(&FREEZE).clear();
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_has(addr: u64) -> c_int {
    if lock(&FREEZE).iter().any(|(a, _, _)| *a == addr) { 1 } else { 0 }
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_count() -> c_int {
    lock(&FREEZE).len() as c_int
}

pub fn start_freeze_thread() {
    std::thread::spawn(|| loop {
        {
            let f = lock(&FREEZE);
            for (addr, _ty, bytes) in f.iter() {
                vm::write_mem(*addr, bytes);
            }
        }
        std::thread::sleep(Duration::from_millis(80));
    });
}
