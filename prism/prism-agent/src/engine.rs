//! Moteur mémoire exposé en C pour l'overlay UIKit (PrismOverlay.m).
//! Même mach vm (vm.rs) que le serveur loopback, mais appelé en direct,
//! en process, sur un état global (l'overlay = une seule session).

use crate::vm::{self, ScanState};
use std::ffi::CString;
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;
use std::time::Duration;

static STATE: Mutex<Option<ScanState>> = Mutex::new(None);
static FREEZE: Mutex<Vec<(u64, i32)>> = Mutex::new(Vec::new());

fn cjson(s: String) -> *mut c_char {
    CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

fn with_state<R>(f: impl FnOnce(&mut ScanState) -> R) -> R {
    let mut g = STATE.lock().unwrap_or_else(|p| p.into_inner());
    let st = g.get_or_insert_with(ScanState::default);
    f(st)
}

fn sample_json(st: &ScanState) -> String {
    let sample: Vec<String> = st.cands.iter().take(100).map(|a| a.to_string()).collect();
    format!("{{\"count\":{},\"sample\":[{}]}}", st.cands.len(), sample.join(","))
}

/// Libère une chaîne rendue par prism_eng_*.
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

/// Première recherche int32. JSON `{count,sample}`.
#[no_mangle]
pub extern "C" fn prism_eng_scan_i32(value: i32) -> *mut c_char {
    with_state(|st| {
        vm::scan_i32(st, value);
        cjson(sample_json(st))
    })
}

/// Une passe d'affinage. `op` = PR_REFINE_*.
#[no_mangle]
pub extern "C" fn prism_eng_refine(op: u8, value: i32) -> *mut c_char {
    with_state(|st| {
        vm::refine(st, op, value);
        cjson(sample_json(st))
    })
}

#[no_mangle]
pub extern "C" fn prism_eng_read_i32(addr: u64, out: *mut i32) -> c_int {
    match vm::read_i32(addr) {
        Some(v) => {
            unsafe { *out = v };
            0
        }
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn prism_eng_write_i32(addr: u64, value: i32) -> c_int {
    if vm::write_i32(addr, value) {
        0
    } else {
        -1
    }
}

// ── Gel (freeze) : réécriture périodique par un thread de fond ───────────────

#[no_mangle]
pub extern "C" fn prism_eng_freeze_add(addr: u64, value: i32) {
    let mut f = FREEZE.lock().unwrap_or_else(|p| p.into_inner());
    f.retain(|(a, _)| *a != addr);
    f.push((addr, value));
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_remove(addr: u64) {
    FREEZE.lock().unwrap_or_else(|p| p.into_inner()).retain(|(a, _)| *a != addr);
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_clear() {
    FREEZE.lock().unwrap_or_else(|p| p.into_inner()).clear();
}

#[no_mangle]
pub extern "C" fn prism_eng_freeze_count() -> c_int {
    FREEZE.lock().unwrap_or_else(|p| p.into_inner()).len() as c_int
}

pub fn start_freeze_thread() {
    std::thread::spawn(|| loop {
        {
            let list = FREEZE.lock().unwrap_or_else(|p| p.into_inner());
            for (addr, value) in list.iter() {
                vm::write_i32(*addr, *value);
            }
        }
        std::thread::sleep(Duration::from_millis(80));
    });
}
