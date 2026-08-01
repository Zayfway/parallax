import SwiftUI

/// Onglet Jumelage.
///
/// Le point délicat de cet écran est que l'utilisateur doit **quitter l'app**
/// au milieu de l'opération, aller dans Réglages, et revenir. Tout est organisé
/// autour de ça :
///
/// - le code à six chiffres est le plus gros élément de l'écran, en mono, pour
///   être mémorisable d'un coup d'œil avant de basculer ;
/// - le chemin dans Réglages est écrit en toutes lettres, parce qu'on ne peut
///   pas y renvoyer par lien profond ;
/// - un rappel explicite dit de laisser Parallax ouvert. C'est la cause n°1
///   d'échec : l'app suspendue cesse de diffuser et rien n'apparaît sous
///   « Jumeler avec ».
struct PairingScreen: View {

    @EnvironmentObject private var pairing: PairingController
    @EnvironmentObject private var connection: DeviceConnection

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

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Jumelage")
                            .font(PX.Font.display(30, .heavy))
                            .foregroundStyle(PX.Color.ink)
                        Text(pairing.hasFile
                             ? "Fichier prêt. Il sert à l'installation et au GPS."
                             : "Sans ordinateur, sur iOS 27.")
                            .font(PX.Font.body(13))
                            .foregroundStyle(PX.Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PX.Space.tight)

                    if let code = pairing.pin {
                        codeCard(code)
                        instructionsCard
                    } else if pairing.hasFile {
                        readyCard
                    } else {
                        startCard
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
    }

    // MARK: - États

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: PX.Space.snug) {
            SectionLabel("Ton code")
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(PX.Font.mono(22, .bold))
                        .foregroundStyle(PX.Color.azimuth)
                        .frame(width: 38, height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                                .fill(PX.Color.azimuth.opacity(0.11))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                                .strokeBorder(PX.Color.azimuth.opacity(0.35), lineWidth: 1)
                        )
                }
            }

            Label("Diffusion en cours — garde Parallax ouvert.", systemImage: "dot.radiowaves.left.and.right")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .padding(PX.Space.base)
        .background(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .fill(PX.Color.azimuth.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(PX.Color.azimuth.opacity(0.30), lineWidth: 1)
        )
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Dans Réglages")

            Step(1) { Text("Confidentialité et sécurité › ") + Text("Mode développeur").bold() }
            Step(2) { Text("Touche ") + Text("Jumeler avec Parallax").bold() }
            Step(3) { Text("Saisis le code de ton iPhone") }
            Step(4) { Text("Recopie les ") + Text("6 chiffres").bold() + Text(" ci-dessus") }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var readyCard: some View {
        VStack(spacing: PX.Space.snug) {
            HStack(spacing: PX.Space.tight) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(PX.Color.verdant)
                Text("Fichier de jumelage prêt")
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Spacer()
            }

            Text("Format RPPairing. Réutilisable indéfiniment sur cet appareil.")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: PX.Space.tight) {
                Button("Exporter") {}
                    .buttonStyle(SecondaryButtonStyle())
                Button("Rejumeler") { Task { await pairing.start() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var startCard: some View {
        VStack(spacing: PX.Space.snug) {
            Text("Parallax fait tourner un hôte de jumelage sur ce téléphone. Ton iPhone s'y connecte par le réseau local — aucun ordinateur.")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Démarrer le jumelage") { Task { await pairing.start() } }
                .buttonStyle(ProminentButtonStyle())
        }
        .padding(PX.Space.base)
        .glassCard()
    }
}

// MARK: -

private struct Step<Content: View>: View {
    let index: Int
    @ViewBuilder let content: () -> Content

    init(_ index: Int, @ViewBuilder content: @escaping () -> Content) {
        self.index = index
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: PX.Space.snug) {
            Text("\(index)")
                .font(PX.Font.mono(10, .bold))
                .foregroundStyle(PX.Color.azimuth)
                .frame(width: 21, height: 21)
                .background(Circle().fill(PX.Color.azimuth.opacity(0.15)))
                .overlay(Circle().strokeBorder(PX.Color.azimuth.opacity(0.4), lineWidth: 1))

            content()
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
       }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PX.Font.display(14, .medium))
            .foregroundStyle(PX.Color.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
                    .strokeBorder(PX.Color.horizon, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
