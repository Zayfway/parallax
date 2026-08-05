//! Contrat de fil host <-> agent. **Source unique** du protocole.
//!
//! Fil : JSON délimité par `\n` — une requête = une ligne, une réponse = une
//! ligne. Simple, débogable, suffisant au jalon 1. Un seul endroit à éditer
//! quand le protocole bouge (miroir de la règle « un seul enum FFI » côté Swift).

use serde::{Deserialize, Serialize};

/// Port loopback fixe de l'agent injecté. Namespace Prism (Parallax = 49152).
pub const PR_AGENT_PORT: u16 = 47821;

// Opérations d'affinage façon GameGuardian (op transmis sur le fil).
pub const PR_REFINE_EQ: u8 = 0; // = X (valeur explicite)
pub const PR_REFINE_INCREASED: u8 = 1; // augmenté vs dernière valeur connue
pub const PR_REFINE_DECREASED: u8 = 2; // diminué
pub const PR_REFINE_UNCHANGED: u8 = 3; // inchangé

/// Requête host -> agent.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Cmd {
    Regions,
    ScanI32 { value: i32 },
    Refine { op: u8, value: i32 },
    ReadI32 { addr: u64 },
    WriteI32 { addr: u64, value: i32 },
}

/// Une région de mémoire virtuelle de la cible.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Region {
    pub addr: u64,
    pub size: u64,
    pub prot: u8, // bits VM_PROT_* (1 R, 2 W, 4 X)
    pub tag: u32,
}

/// Réponse agent -> host.
#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "reply", rename_all = "snake_case")]
pub enum Reply {
    Regions { regions: Vec<Region> },
    /// `sample` = les 64 premières adresses candidates (mono côté UI).
    Scan { count: usize, sample: Vec<u64> },
    Value { addr: u64, value: i32 },
    Ok,
    Err { message: String },
}
