// Pont de log Rust -> Swift. Le callback C ne peut pas capturer de contexte,
// d'où un singleton et un `install()` non isolé (cf. FFI.swift, `prScanLog`).

import Foundation

@MainActor
final class LogBridge: ObservableObject {
    static let shared = LogBridge()
    @Published private(set) var lines: [String] = []

    nonisolated static func install() {
        pr_log_init(prScanLog)
    }

    func append(_ s: String) {
        lines.append(s)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }
}
