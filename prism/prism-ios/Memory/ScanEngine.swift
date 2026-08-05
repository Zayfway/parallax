// @MainActor ObservableObject. Publie `writing` (pilote l'ambre), l'ensemble de
// candidats, l'échantillon. TOUT appel FFI bloquant part sur
// DispatchQueue.global(qos:) — jamais dans une Task (le pool coopératif a un
// thread par cœur ; le saturer gèle l'app).

import SwiftUI

@MainActor
final class ScanEngine: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connected
        case scanned(Int)
        case refined(Int)
        case locked(UInt64)
        case writing(UInt64)
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Aucune session"
            case .connected: "Agent connecté"
            case .scanned(let n): "\(n) candidats"
            case .refined(let n): "\(n) candidats"
            case .locked: "Candidat verrouillé"
            case .writing: "Écriture active"
            case .failed(let m): "Échec — \(m)"
            }
        }
        var tint: Color {
            switch self {
            case .idle: PR.Color.inkFaint
            case .connected, .scanned, .refined: PR.Color.azimuth
            case .locked: PR.Color.verdant
            case .writing: PR.Color.signal // le SEUL cas ambre
            case .failed: PR.Color.alert
            }
        }
        var icon: String {
            switch self {
            case .idle: "moon.zzz"
            case .connected: "bolt.horizontal.circle"
            case .scanned, .refined: "scope"
            case .locked: "lock.fill"
            case .writing: "pencil.and.outline"
            case .failed: "exclamationmark.triangle"
            }
        }
        var step: Int {
            switch self {
            case .idle, .failed: 0
            case .connected: 1
            case .scanned: 2
            case .refined, .locked: 3
            case .writing: 4
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var writing = false
    @Published var profile = ""
    @Published var regions: [MemRegion] = []
    @Published var candidateCount = 0
    @Published var sample: [UInt64] = []
    @Published var lastAddress: UInt64?
    @Published var lastValue: Int32?
    @Published var busy = false

    private var session: OpaquePointer?
    var connected: Bool { session != nil }

    init() { profile = FFI.buildProfile() }

    // Exécute un travail FFI bloquant hors du pool coopératif.
    private func offMain(_ work: @escaping (OpaquePointer) throws -> Void) {
        guard let s = session else { phase = .failed("pas de session"); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work(s)
            } catch {
                let msg = (error as? FFI.Failure)?.detail ?? "\(error)"
                DispatchQueue.main.async { self.busy = false; self.phase = .failed(msg) }
            }
        }
    }

    func connect(port: UInt16 = 47821) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let s = try FFI.open(port: port)
                DispatchQueue.main.async { self.session = s; self.busy = false; self.phase = .connected }
            } catch {
                let msg = (error as? FFI.Failure)?.detail ?? "\(error)"
                DispatchQueue.main.async { self.busy = false; self.phase = .failed(msg) }
            }
        }
    }

    func loadRegions() {
        offMain { s in
            let r = try FFI.regions(s)
            DispatchQueue.main.async { self.regions = r; self.busy = false }
        }
    }

    func scan(_ value: Int32) {
        offMain { s in
            let r = try FFI.scan(s, value: value)
            DispatchQueue.main.async {
                self.candidateCount = r.count
                self.sample = r.sample
                self.lastAddress = r.sample.first
                self.lastValue = value
                self.busy = false
                self.phase = .scanned(r.count)
            }
        }
    }

    func refine(op: Int32, value: Int32) {
        offMain { s in
            let r = try FFI.refine(s, op: op, value: value)
            DispatchQueue.main.async {
                self.candidateCount = r.count
                self.sample = r.sample
                self.lastAddress = r.sample.first
                self.busy = false
                self.phase = r.count == 1 ? .locked(r.sample.first ?? 0) : .refined(r.count)
            }
        }
    }

    func write(addr: UInt64, value: Int32) {
        offMain { s in
            try FFI.write(s, addr: addr, value: value)
            let back = try? FFI.read(s, addr: addr) // relecture de confirmation
            DispatchQueue.main.async {
                self.busy = false
                self.writing = true // ← allume l'ambre, partout
                self.phase = .writing(addr)
                self.lastAddress = addr
                self.lastValue = back ?? value
            }
        }
    }

    func disconnect() {
        if let s = session { FFI.close(s); session = nil }
        writing = false
        phase = .idle
        regions = []
        candidateCount = 0
        sample = []
        lastAddress = nil
        lastValue = nil
    }
}
