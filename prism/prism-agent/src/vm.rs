//! Opérations mach sur `mach_task_self()` — la tâche de la cible elle-même,
//! une fois l'agent injecté. Aucun entitlement privilégié (modèle GameGuardian
//! in-process). Compilé pour iOS/simulateur uniquement.

use mach2::kern_return::KERN_SUCCESS;
use mach2::message::mach_msg_type_number_t;
use mach2::port::mach_port_t;
use mach2::traps::mach_task_self;
use mach2::vm::{mach_vm_protect, mach_vm_read_overwrite, mach_vm_region, mach_vm_write};
use mach2::vm_prot::{VM_PROT_READ, VM_PROT_WRITE};
use mach2::vm_region::{vm_region_basic_info_data_64_t, vm_region_info_t, VM_REGION_BASIC_INFO_64};
use mach2::vm_types::{mach_vm_address_t, mach_vm_size_t, vm_offset_t};
use prism_proto::{
    Region, PR_REFINE_DECREASED, PR_REFINE_EQ, PR_REFINE_INCREASED, PR_REFINE_UNCHANGED,
};

const CHUNK: u64 = 8 * 1024 * 1024; // lecture par tranches de 8 Mo
const MAX_REGION: u64 = 512 * 1024 * 1024; // ignore les régions démesurées
const MAX_CANDS: usize = 200_000; // borne mémoire de l'ensemble de candidats

#[derive(Default)]
pub struct ScanState {
    pub cands: Vec<u64>,
    pub last: Vec<i32>,
}

fn task() -> mach_port_t {
    unsafe { mach_task_self() }
}

/// Énumère les régions VM de la tâche courante.
pub fn regions() -> Vec<Region> {
    let t = task();
    let mut out = Vec::new();
    let mut addr: mach_vm_address_t = 1;
    loop {
        let mut size: mach_vm_size_t = 0;
        let mut info: vm_region_basic_info_data_64_t = unsafe { std::mem::zeroed() };
        let mut count: mach_msg_type_number_t =
            (std::mem::size_of::<vm_region_basic_info_data_64_t>() / std::mem::size_of::<i32>())
                as mach_msg_type_number_t;
        let mut object_name: mach_port_t = 0;
        let kr = unsafe {
            mach_vm_region(
                t,
                &mut addr,
                &mut size,
                VM_REGION_BASIC_INFO_64,
                &mut info as *mut _ as vm_region_info_t,
                &mut count,
                &mut object_name,
            )
        };
        if kr != KERN_SUCCESS {
            break;
        }
        out.push(Region {
            addr,
            size,
            prot: info.protection as u8,
            tag: 0,
        });
        addr = match addr.checked_add(size) {
            Some(a) if a > addr => a,
            _ => break,
        };
        if out.len() > 100_000 {
            break; // garde-fou
        }
    }
    out
}

fn read_bytes(t: mach_port_t, addr: u64, buf: &mut [u8]) -> Option<usize> {
    let mut outsize: mach_vm_size_t = 0;
    let kr = unsafe {
        mach_vm_read_overwrite(
            t,
            addr,
            buf.len() as mach_vm_size_t,
            buf.as_mut_ptr() as mach_vm_address_t,
            &mut outsize,
        )
    };
    if kr == KERN_SUCCESS {
        Some(outsize as usize)
    } else {
        None
    }
}

pub fn read_i32(addr: u64) -> Option<i32> {
    let mut b = [0u8; 4];
    match read_bytes(task(), addr, &mut b) {
        Some(4) => Some(i32::from_ne_bytes(b)),
        _ => None,
    }
}

/// Recherche initiale : ne scanne que les régions lisibles+inscriptibles (les
/// valeurs mutables vivent en RW), par tranches, alignement 4 octets.
pub fn scan_i32(st: &mut ScanState, value: i32) {
    st.cands.clear();
    st.last.clear();
    let t = task();
    let rw = (VM_PROT_READ | VM_PROT_WRITE) as u8;
    let mut buf = vec![0u8; CHUNK as usize];
    for r in regions() {
        if r.prot & rw != rw || r.size == 0 || r.size > MAX_REGION {
            continue;
        }
        let mut off: u64 = 0;
        while off < r.size {
            let this = std::cmp::min(CHUNK, r.size - off) as usize;
            let got = match read_bytes(t, r.addr + off, &mut buf[..this]) {
                Some(n) => n,
                None => break,
            };
            let mut i = 0usize;
            while i + 4 <= got {
                let v = i32::from_ne_bytes([buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]);
                if v == value {
                    st.cands.push(r.addr + off + i as u64);
                    st.last.push(v);
                    if st.cands.len() >= MAX_CANDS {
                        return;
                    }
                }
                i += 4;
            }
            off += this as u64;
        }
    }
}

/// Une passe d'affinage : relit chaque candidat, compare à la dernière valeur
/// (INCREASED/DECREASED/UNCHANGED) ou à `value` (EQ), met à jour `last`.
pub fn refine(st: &mut ScanState, op: u8, value: i32) {
    let mut keep_addr = Vec::new();
    let mut keep_val = Vec::new();
    for (i, &addr) in st.cands.iter().enumerate() {
        let Some(cur) = read_i32(addr) else { continue };
        let prev = st.last.get(i).copied().unwrap_or(cur);
        let ok = match op {
            PR_REFINE_EQ => cur == value,
            PR_REFINE_INCREASED => cur > prev,
            PR_REFINE_DECREASED => cur < prev,
            PR_REFINE_UNCHANGED => cur == prev,
            _ => false,
        };
        if ok {
            keep_addr.push(addr);
            keep_val.push(cur);
        }
    }
    st.cands = keep_addr;
    st.last = keep_val;
}

/// L'écriture : s'assure que la page est inscriptible (`vm_protect`), écrit 4
/// octets. Renvoie `false` -> `PR_ERR_WRITE` côté hôte.
pub fn write_i32(addr: u64, value: i32) -> bool {
    let t = task();
    unsafe {
        mach_vm_protect(t, addr as mach_vm_address_t, 4, 0, VM_PROT_READ | VM_PROT_WRITE);
    }
    let bytes = value.to_ne_bytes();
    let kr = unsafe {
        mach_vm_write(
            t,
            addr as mach_vm_address_t,
            bytes.as_ptr() as vm_offset_t,
            bytes.len() as mach_msg_type_number_t,
        )
    };
    kr == KERN_SUCCESS
}
