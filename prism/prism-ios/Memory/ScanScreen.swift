// Référence de composition Prism : machine à phases dérivée de l'état du moteur
// (miroir de PairingScreen), banner unique coloré, rail d'étapes, cascade.
// L'ambre n'apparaît QUE dans la phase `.writing`.

import SwiftUI

struct ScanScreen: View {
    @EnvironmentObject private var engine: ScanEngine
    @State private var shown = false
    @State private var scanValue = ""
    @State private var writeValue = ""

    private var phase: ScanEngine.Phase { engine.phase }

    var body: some View {
        ZStack {
            PR.Color.canvas
            ScrollView {
                VStack(alignment: .leading, spacing: PR.Space.base) {
                    ScreenHeader("Mémoire", "Scanne la RAM de la cible") {
                        Tag(icon: "cpu",
                            text: engine.profile.contains("stub") ? "stub" : "natif",
                            tint: engine.profile.contains("stub") ? PR.Color.inkFaint : PR.Color.verdant)
                    }
                    .appear(0, shown)

                    statusBanner.appear(1, shown)

                    InstrumentStrip(address: engine.lastAddress, value: engine.lastValue,
                                    sessionLabel: phase.label, live: engine.busy)
                        .appear(2, shown)

                    rail.appear(3, shown)

                    if engine.connected {
                        searchCard.appear(4, shown)
                        if engine.candidateCount > 0 || phase.step >= 2 {
                            refineCard.appear(5, shown)
                            writeCard.appear(6, shown)
                        }
                    } else {
                        connectCard.appear(4, shown)
                    }
                }
                .padding(.horizontal, PR.Space.base)
                .padding(.bottom, 110)
            }
        }
        .animation(PR.Motion.settle, value: engine.phase)
        .animation(PR.Motion.settle, value: engine.connected)
        .onAppear { shown = true }
    }

    // Le seul élément qui change de couleur — il porte l'état à lui seul.
    private var statusBanner: some View {
        HStack(spacing: PR.Space.snug) {
            Image(systemName: phase.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(phase.tint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label).font(PR.Font.display(16, .semibold)).foregroundStyle(PR.Color.ink)
                Text("\(engine.candidateCount) candidats")
                    .font(PR.Font.mono(12)).foregroundStyle(PR.Color.inkMuted)
            }
            Spacer()
            if engine.busy { ProgressView().tint(phase.tint) }
        }
        .padding(PR.Space.base)
        .glassCard(emphasis: true)
        .overlay(RoundedRectangle(cornerRadius: PR.Radius.card, style: .continuous)
            .strokeBorder(phase.tint.opacity(0.34), lineWidth: 1))
        .signalGlow(engine.writing)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: PR.Space.snug) {
            SectionLabel("Session")
            Text("L'agent injecté écoute sur 127.0.0.1:47821. Connecte-toi pour lister et scanner la mémoire.")
                .font(PR.Font.body(14)).foregroundStyle(PR.Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { engine.connect() } label: { Text("Connecter l'agent") }
                .buttonStyle(ProminentButtonStyle(enabled: !engine.busy))
                .disabled(engine.busy)
        }
        .padding(PR.Space.base).glassCard()
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: PR.Space.snug) {
            SectionLabel("Recherche")
            TextField("valeur", text: $scanValue)
                .keyboardType(.numbersAndPunctuation)
                .field("Valeur int32", mono: true)
            Button {
                if let v = Int32(scanValue.trimmingCharacters(in: .whitespaces)) { engine.scan(v) }
            } label: { Text("Rechercher") }
                .buttonStyle(ProminentButtonStyle(enabled: canScan))
                .disabled(!canScan)
        }
        .padding(PR.Space.base).glassCard()
    }
    private var canScan: Bool {
        !engine.busy && Int32(scanValue.trimmingCharacters(in: .whitespaces)) != nil
    }

    private var refineCard: some View {
        VStack(alignment: .leading, spacing: PR.Space.snug) {
            SectionLabel("Affiner")
            HStack(spacing: PR.Space.tight) {
                refineButton("=", PR_REFINE_EQ)
                refineButton("▲", PR_REFINE_INCREASED)
                refineButton("▼", PR_REFINE_DECREASED)
                refineButton("≈", PR_REFINE_UNCHANGED)
            }
            if !engine.sample.isEmpty { sampleList }
        }
        .padding(PR.Space.base).glassCard()
    }

    private func refineButton(_ label: String, _ op: Int32) -> some View {
        Button {
            let v = Int32(scanValue.trimmingCharacters(in: .whitespaces)) ?? 0
            engine.refine(op: op, value: v)
        } label: {
            Text(label)
                .font(PR.Font.mono(16, .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(PR.Color.strata.opacity(0.6)))
                .foregroundStyle(PR.Color.ink)
        }
        .disabled(engine.busy)
    }

    private var sampleList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(engine.sample.prefix(6), id: \.self) { addr in
                Text(String(format: "0x%010llX", addr))
                    .font(PR.Font.mono(13)).foregroundStyle(PR.Color.inkMuted)
            }
            if engine.candidateCount > 6 {
                Text("+ \(engine.candidateCount - 6) autres")
                    .font(PR.Font.body(12)).foregroundStyle(PR.Color.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var writeCard: some View {
        VStack(alignment: .leading, spacing: PR.Space.snug) {
            SectionLabel("Écrire")
            if let addr = engine.lastAddress {
                Text(String(format: "cible : 0x%010llX", addr))
                    .font(PR.Font.mono(13)).foregroundStyle(PR.Color.inkMuted)
            }
            TextField("nouvelle valeur", text: $writeValue)
                .keyboardType(.numbersAndPunctuation)
                .field("Nouvelle valeur int32", mono: true)
            Button {
                if let addr = engine.lastAddress,
                   let v = Int32(writeValue.trimmingCharacters(in: .whitespaces)) {
                    engine.write(addr: addr, value: v)
                }
            } label: { Text("Écrire en mémoire") }
                .buttonStyle(ProminentButtonStyle(tint: PR.Color.signal, enabled: canWrite))
                .disabled(!canWrite)
        }
        .padding(PR.Space.base).glassCard()
    }
    private var canWrite: Bool {
        !engine.busy && engine.lastAddress != nil
            && Int32(writeValue.trimmingCharacters(in: .whitespaces)) != nil
    }

    // Rail d'étapes : connexion → valeur → affiner → écrire.
    private var rail: some View {
        VStack(spacing: 0) {
            railStep(1, "Connexion", "agent loopback")
            connector(filled: phase.step > 1)
            railStep(2, "Valeur", "recherche int32")
            connector(filled: phase.step > 2)
            railStep(3, "Affiner", "réduire les candidats")
            connector(filled: phase.step > 3)
            railStep(4, "Écrire", "poser la valeur")
        }
        .padding(PR.Space.base).glassCard()
    }

    private func railStep(_ number: Int, _ heading: String, _ detail: String) -> some View {
        let active = phase.step == number
        let done = phase.step > number
        return HStack(alignment: .top, spacing: PR.Space.snug) {
            ZStack {
                Circle()
                    .fill(done ? PR.Color.verdant.opacity(0.18)
                          : active ? PR.Color.azimuth.opacity(0.20)
                          : .white.opacity(0.04))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(PR.Color.verdant)
                } else {
                    Text("\(number)").font(PR.Font.mono(12, .bold))
                        .foregroundStyle(active ? PR.Color.azimuth : PR.Color.inkFaint)
                }
            }
            .overlay(Circle().strokeBorder(active ? PR.Color.azimuth.opacity(0.55) : .clear, lineWidth: 1.2))
            .scaleEffect(active ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(heading).font(PR.Font.body(15, .semibold)).foregroundStyle(PR.Color.ink)
                Text(detail).font(PR.Font.body(12)).foregroundStyle(PR.Color.inkMuted)
            }
            Spacer()
        }
        .animation(PR.Motion.settle, value: phase.step)
    }

    private func connector(filled: Bool) -> some View {
        HStack {
            Rectangle()
                .fill(filled ? PR.Color.verdant.opacity(0.6) : PR.Color.horizon)
                .frame(width: 1.5, height: 22)
                .padding(.leading, 13)
            Spacer()
        }
        .animation(PR.Motion.settle, value: filled)
    }
}
