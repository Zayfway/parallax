// Carte mémoire de la cible : adresse (mono), protections rwx, taille.
// Tout est en mono — ça vient de la mémoire de l'appareil (règle 2).

import SwiftUI

struct RegionsScreen: View {
    @EnvironmentObject private var engine: ScanEngine
    @State private var shown = false

    var body: some View {
        ZStack {
            PR.Color.canvas
            ScrollView {
                VStack(alignment: .leading, spacing: PR.Space.base) {
                    ScreenHeader("Régions", "Carte mémoire de la cible").appear(0, shown)

                    if !engine.connected {
                        emptyCard("Aucune session", "Connecte l'agent depuis l'onglet Mémoire.")
                            .appear(1, shown)
                    } else {
                        Button { engine.loadRegions() } label: { Text("Charger les régions") }
                            .buttonStyle(ProminentButtonStyle(enabled: !engine.busy))
                            .disabled(engine.busy)
                            .appear(1, shown)

                        ForEach(Array(engine.regions.prefix(200).enumerated()), id: \.offset) { i, r in
                            regionRow(r).appear(min(i + 2, 8), shown)
                        }
                        if engine.regions.count > 200 {
                            Text("+ \(engine.regions.count - 200) régions")
                                .font(PR.Font.body(12)).foregroundStyle(PR.Color.inkFaint)
                        }
                    }
                }
                .padding(.horizontal, PR.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear { shown = true }
    }

    private func regionRow(_ r: MemRegion) -> some View {
        HStack {
            Text(String(format: "0x%010llX", r.addr))
                .font(PR.Font.mono(13, .semibold)).foregroundStyle(PR.Color.ink)
            Spacer()
            Text(r.protString).font(PR.Font.mono(12)).foregroundStyle(PR.Color.azimuth)
            Text(byteSize(r.size))
                .font(PR.Font.mono(12)).foregroundStyle(PR.Color.inkMuted)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, PR.Space.base).padding(.vertical, PR.Space.snug)
        .glassCard(radius: PR.Radius.chip)
    }

    private func emptyCard(_ t: String, _ s: String) -> some View {
        VStack(spacing: 6) {
            Text(t).font(PR.Font.display(16, .semibold)).foregroundStyle(PR.Color.ink)
            Text(s).font(PR.Font.body(14)).foregroundStyle(PR.Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(PR.Space.loose).glassCard()
    }

    private func byteSize(_ n: UInt64) -> String {
        let u = ["o", "Ko", "Mo", "Go"]
        var v = Double(n)
        var i = 0
        while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
        return String(format: (v < 10 && i > 0) ? "%.1f%@" : "%.0f%@", v, u[i])
    }
}
