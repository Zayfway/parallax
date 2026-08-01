import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// ONGLET JUMELAGE
//
// La difficulté de cet écran n'est pas technique, elle est d'attention :
// l'utilisateur doit **quitter l'app au milieu de l'opération**, retenir six
// chiffres, naviguer dans Réglages, et revenir. Tout est organisé pour ça.
//
// ── LA COULEUR PORTE L'AVANCEMENT ─────────────────────────────────────────
// Une seule chose doit être lisible d'un coup d'œil : où on en est.
//
//   gris      · rien ne se passe
//   pervenche · diffusion en cours, l'appareil peut nous trouver
//   vert      · fichier obtenu, terminé
//   rouge     · échec
//
// L'ambre n'apparaît **jamais** ici. Il est réservé à « position simulée
// active », et une couleur signature qui déborde cesse d'être un signal.
//
// ── LE RAIL ───────────────────────────────────────────────────────────────
// Trois étapes reliées par un trait qui se remplit. On ne numérote pas pour
// décorer : à chaque instant, une seule étape est allumée, les autres sont
// éteintes. C'est ce qui dit « tu es ici » sans une ligne de texte.
// ═══════════════════════════════════════════════════════════════════════════

struct PairingScreen: View {

    @EnvironmentObject private var pairing: PairingController
    @EnvironmentObject private var connection: DeviceConnection

    @State private var shown = false

    // MARK: - Phase

    enum Phase {
        case dormant        // rien n'a commencé
        case broadcasting   // on diffuse, l'appareil ne s'est pas encore manifesté
        case code(String)   // le PIN est là, l'utilisateur doit filer dans Réglages
        case ready          // fichier de jumelage obtenu
        case failed(String)

        var step: Int {
            switch self {
            case .dormant, .failed: 0
            case .broadcasting:     1
            case .code:             2
            case .ready:            4
            }
        }

        var tint: Color {
            switch self {
            case .dormant:      PX.Color.inkFaint
            case .broadcasting: PX.Color.azimuth
            case .code:         PX.Color.azimuth
            case .ready:        PX.Color.verdant
            case .failed:       PX.Color.alert
            }
        }

        var label: String {
            switch self {
            case .dormant:      "En veille"
            case .broadcasting: "Diffusion"
            case .code:         "Code affiché"
            case .ready:        "Fichier prêt"
            case .failed:       "Échec"
            }
        }

        var icon: String {
            switch self {
            case .dormant:      "moon.zzz"
            case .broadcasting: "dot.radiowaves.left.and.right"
            case .code:         "number"
            case .ready:        "checkmark.seal.fill"
            case .failed:       "exclamationmark.triangle.fill"
            }
        }
    }

    private var phase: Phase {
        if let error = pairing.lastError { return .failed(error) }
        if let pin = pairing.pin { return .code(pin) }
        if pairing.isRunning { return .broadcasting }
        if pairing.hasFile { return .ready }
        return .dormant
    }

    // MARK: - Corps

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {

                    InstrumentStrip(
                        latitude: nil, longitude: nil,
                        sessionLabel: "\(connection.deviceIP) : 49152",
                        live: false
                    )
                    .appear(0, shown)

                    title
                        .appear(1, shown)

                    statusBanner
                        .appear(2, shown)

                    if case .code(let pin) = phase {
                        pinCard(pin)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.94).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    rail
                        .appear(3, shown)

                    action
                        .appear(4, shown)

                    if case .failed(let message) = phase {
                        errorCard(message)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .animation(PX.Motion.settle, value: pairing.isRunning)
        .animation(PX.Motion.acquire, value: pairing.pin)
        .animation(PX.Motion.settle, value: pairing.hasFile)
        .animation(PX.Motion.settle, value: pairing.lastError)
        .onAppear { shown = true }
    }

    // MARK: - Titre

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Jumelage")
                .font(PX.Font.display(30, .heavy))
                .foregroundStyle(PX.Color.ink)
            Text("Sans ordinateur, directement depuis Réglages.")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PX.Space.tight)
    }

    // MARK: - Bandeau d'état

    /// Le seul élément qui change de couleur. Il porte l'état à lui seul, ce
    /// qui évite d'avoir à teinter six composants et à les tenir synchronisés.
    private var statusBanner: some View {
        HStack(spacing: PX.Space.snug) {
            PulseDot(color: phase.tint, active: phase.step == 1 || phase.step == 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(PX.Font.mono(11))
                    .foregroundStyle(PX.Color.inkMuted)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)

            Image(systemName: phase.icon)
                .font(.system(size: 19))
                .foregroundStyle(phase.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(phase.tint.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: phase.tint.opacity(0.22), radius: 16, y: 6)
    }

    private var subtitle: String {
        switch phase {
        case .dormant:      "aucune diffusion"
        case .broadcasting: "en attente de l'appareil"
        case .code:         "saisis le code dans Réglages"
        case .ready:        "prêt pour l'installation et le GPS"
        case .failed:       "voir le détail ci-dessous"
        }
    }

    // MARK: - Le code

    /// Six cellules plutôt qu'une chaîne : les chiffres se lisent par paires
    /// et se retiennent, ce qui est tout l'enjeu au moment de basculer vers
    /// Réglages. Elles entrent en cascade, de gauche à droite.
    private func pinCard(_ pin: String) -> some View {
        VStack(spacing: PX.Space.snug) {
            SectionLabel("Code de jumelage")

            HStack(spacing: PX.Space.tight) {
                ForEach(Array(pin.enumerated()), id: \.offset) { index, digit in
                    Text(String(digit))
                        .font(PX.Font.mono(30, .bold))
                        .monospacedDigit()
                        .foregroundStyle(PX.Color.ink)
                        .frame(width: 44, height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                                .fill(PX.Color.night.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                                .strokeBorder(PX.Color.azimuth.opacity(0.45), lineWidth: 1)
                        )
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        .animation(PX.Motion.acquire.delay(Double(index) * 0.06), value: pin)
                }
            }

            Text("Laisse Parallax ouvert. Une app suspendue cesse de diffuser, et l'entrée disparaît de Réglages.")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
    }

    // MARK: - Rail d'étapes

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Marche à suivre")
                .padding(.bottom, PX.Space.snug)

            step(1, "Lancer la diffusion",
                 "Parallax s'annonce sur le réseau local.")
            connector(filled: phase.step >= 2)
            step(2, "Réglages › Confidentialité et sécurité › Mode développeur",
                 "Touche « Pair with Parallax » sous Autres appareils.")
            connector(filled: phase.step >= 3)
            step(3, "Saisir le code",
                 "Recopie les six chiffres dans la demande affichée par Réglages.")
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func step(_ number: Int, _ heading: String, _ detail: String) -> some View {
        let active = phase.step == number
        let done = phase.step > number

        return HStack(alignment: .top, spacing: PX.Space.snug) {
            ZStack {
                Circle()
                    .fill(done ? PX.Color.verdant.opacity(0.18)
                               : active ? PX.Color.azimuth.opacity(0.20)
                                        : Color.white.opacity(0.04))
                    .frame(width: 28, height: 28)

                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PX.Color.verdant)
                } else {
                    Text("\(number)")
                        .font(PX.Font.mono(12, .bold))
                        .foregroundStyle(active ? PX.Color.azimuth : PX.Color.inkFaint)
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(active ? PX.Color.azimuth.opacity(0.55) : .clear, lineWidth: 1.2)
                    .frame(width: 28, height: 28)
            )
            .scaleEffect(active ? 1.06 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(PX.Font.display(13.5, .semibold))
                    .foregroundStyle(active || done ? PX.Color.ink : PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(PX.Font.body(12))
                    .foregroundStyle(active ? PX.Color.inkMuted : PX.Color.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .animation(PX.Motion.settle, value: phase.step)
    }

    /// Le trait qui relie deux étapes. Il se remplit vers le bas : c'est le
    /// seul endroit où la progression est représentée comme un mouvement.
    private func connector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? PX.Color.verdant.opacity(0.6) : PX.Color.horizon)
            .frame(width: 1.5, height: 22)
            .padding(.leading, 13)
            .animation(PX.Motion.settle, value: filled)
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch phase {
        case .ready:
            VStack(spacing: PX.Space.tight) {
                ShareLink(item: PairingStore.fileURL) {
                    Label("Exporter le fichier", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ProminentButtonStyle())
                Button {
                    Task { await pairing.start() }
                } label: {
                    Label("Rejumeler", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

        case .broadcasting, .code:
            HStack(spacing: PX.Space.tight) {
                ProgressView().tint(PX.Color.azimuth)
                Text("Diffusion en cours — garde l'app ouverte")
                    .font(PX.Font.mono(11))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassCard(radius: PX.Radius.control)

        default:
            Button {
                Task { await pairing.start() }
            } label: {
                Label("Démarrer le jumelage", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(ProminentButtonStyle())
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: PX.Space.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PX.Color.alert)
            Text(message)
                .font(PX.Font.body(12.5))
                .foregroundStyle(PX.Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(PX.Color.alert.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Point pulsant

/// Halo qui respire pendant la diffusion. Deux cercles concentriques : le
/// noyau reste net, l'anneau s'étale et s'efface. C'est ce qui distingue
/// « en attente » de « figé », sans texte.
struct PulseDot: View {
    let color: Color
    let active: Bool

    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(active ? 0.5 : 0), lineWidth: 1.4)
                .frame(width: 26, height: 26)
                .scaleEffect(expanded && active ? 1.5 : 0.85)
                .opacity(expanded && active ? 0 : 1)

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.7), radius: active ? 7 : 0)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
        .animation(PX.Motion.settle, value: active)
        .animation(PX.Motion.settle, value: color)
    }
}
