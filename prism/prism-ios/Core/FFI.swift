// Seul endroit du projet qui appelle `pr_*`. Façade sans-cas : conversions,
// libération mémoire (le tas appartient à Rust), codes -> `throws`.

import Foundation

struct MemRegion: Decodable, Identifiable {
    let addr: UInt64
    let size: UInt64
    let prot: UInt8
    let tag: UInt32
    var id: UInt64 { addr }
    var protString: String {
        var s = ""
        s += (prot & 1) != 0 ? "r" : "-"
        s += (prot & 2) != 0 ? "w" : "-"
        s += (prot & 4) != 0 ? "x" : "-"
        return s
    }
}

struct ScanResult: Decodable {
    let count: Int
    let sample: [UInt64]
}

enum FFI {
    struct Failure: LocalizedError {
        let code: Int32
        let detail: String?
        var errorDescription: String? { detail ?? "erreur native (\(code))" }
    }

    static var lastError: String? {
        guard let p = pr_last_error() else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    static func check(_ c: Int32) throws {
        guard c != PR_OK else { return }
        throw Failure(code: c, detail: lastError)
    }

    static func buildProfile() -> String {
        guard let p = pr_build_profile() else { return "" }
        return String(cString: p)
    }

    /// Ouvre le canal loopback. Fermé par `close(_:)`.
    static func open(host: String = "127.0.0.1", port: UInt16) throws -> OpaquePointer {
        guard let s = host.withCString({ pr_session_open($0, port) }) else {
            throw Failure(code: PR_ERR_NO_AGENT, detail: lastError)
        }
        return s
    }
    static func close(_ s: OpaquePointer) { pr_session_close(s) }

    static func regions(_ s: OpaquePointer) throws -> [MemRegion] {
        guard let raw = pr_regions_list(s) else { throw Failure(code: PR_ERR_REGION, detail: lastError) }
        defer { pr_string_free(raw) } // le tas appartient à Rust — libérer AVANT le décodage
        return try JSONDecoder().decode([MemRegion].self, from: Data(String(cString: raw).utf8))
    }
    static func scan(_ s: OpaquePointer, value: Int32) throws -> ScanResult {
        guard let raw = pr_scan_i32(s, value) else { throw Failure(code: PR_ERR_INTERNAL, detail: lastError) }
        defer { pr_string_free(raw) }
        return try JSONDecoder().decode(ScanResult.self, from: Data(String(cString: raw).utf8))
    }
    static func refine(_ s: OpaquePointer, op: Int32, value: Int32) throws -> ScanResult {
        guard let raw = pr_scan_refine(s, op, value) else { throw Failure(code: PR_ERR_SCAN_STATE, detail: lastError) }
        defer { pr_string_free(raw) }
        return try JSONDecoder().decode(ScanResult.self, from: Data(String(cString: raw).utf8))
    }
    static func read(_ s: OpaquePointer, addr: UInt64) throws -> Int32 {
        var out: Int32 = 0
        try check(pr_mem_read_i32(s, addr, &out))
        return out
    }
    /// L'UNIQUE écriture — c'est elle qui allume l'ambre côté UI.
    static func write(_ s: OpaquePointer, addr: UInt64, value: Int32) throws {
        try check(pr_mem_write_i32(s, addr, value)) // u64 <-> UInt64, jamais Int
    }
}

/// **Portée fichier, donc non isolée.** Une closure `@MainActor` en hériterait
/// l'isolation et le runtime trappe (`swift_task_checkIsolated`) dès que Rust
/// l'appelle depuis un de ses threads. Même piège que `pxPinSink` de Parallax.
func prScanLog(_ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let s = String(cString: line)
    Task { @MainActor in LogBridge.shared.append(s) }
}
