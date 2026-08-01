import SwiftUI

/// Onglet Certificats.
///
/// Existe pour une raison précise : Apple limite un compte développeur gratuit
/// à **trois certificats**. Quand la limite est atteinte, la signature échoue
/// avec un message Apple opaque, et l'utilisateur n'a aucun moyen de voir ce
/// qui occupe ses emplacements ni d'en libérer un. C'est la cause d'abandon
/// la plus fréquente sur ce type d'outil.
///
/// L'écran affiche donc les emplacements consommés avant toute action, et
/// permet de révoquer. Révoquer casse les apps déjà signées avec ce
/// certificat — l'avertissement est donc dans la confirmation, pas en note de
/// bas de page.
struct CertificatesScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @State private var certificates: [Certificate] = []
    @State private var pendingRevocation: Certificate?

    struct Certificate: Identifiable, Equatable {
        let id: String
        let machineName: String
        let fingerprint: String
        let expiry: Date
        /// Vrai si l'empreinte correspond à celle utilisée par cet appareil.
        let isCurrentDevice: Bool
    }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    InstrumentStrip(
                        latitude: nil, longitude: nil,
                        sessionLabel: "\(certificates.count) / 3 emplacements",
                        live: false
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Certificats")
                            .font(PX.Font.display(30, .heavy))
                            .foregroundStyle(PX.Color.ink)
                        Text("Apple en autorise trois par compte gratuit.")
                            .font(PX.Font.body(13))
                            .foregroundStyle(PX.Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, PX.Space.tight)

                    if certificates.isEmpty {
                        emptyState
                    } else {
                        ForEach(certificates) { certificate in
                            card(certificate)
                        }
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .confirmationDialog(
            "Révoquer ce certificat ?",
            isPresented: .constant(pendingRevocation != nil),
            titleVisibility: .visible
        ) {
            Button("Révoquer", role: .destructive) {
                if let target = pendingRevocation { revoke(target) }
                pendingRevocation = nil
            }
            Button("Annuler", role: .cancel) { pendingRevocation = nil }
        } message: {
            Text("Toutes les apps signées avec ce certificat cesseront de s'ouvrir jusqu'à leur resignature.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: PX.Space.tight) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 30))
                .foregroundStyle(PX.Color.inkFaint)
            Text("Aucun certificat")
                .font(PX.Font.display(15, .semibold))
                .foregroundStyle(PX.Color.ink)
            Text("Connecte-toi dans l'onglet Installer pour en créer un.")
                .font(PX.Font.body(12.5))
                .foregroundStyle(PX.Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PX.Space.wide)
        .padding(.horizontal, PX.Space.base)
        .glassCard()
    }

    private func card(_ certificate: Certificate) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack {
                Text(certificate.machineName)
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Spacer()
                if certificate.isCurrentDevice {
                    Tag("Actif", color: PX.Color.verdant, icon: "checkmark.circle.fill")
                } else {
                    Tag("Inutilisé", color: PX.Color.alert, icon: "exclamationmark.circle.fill")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Row("SHA-1", certificate.fingerprint)
                Row("Expire", certificate.expiry.formatted(date: .abbreviated, time: .omitted))
            }

            if !certificate.isCurrentDevice {
                Button("Révoquer") { pendingRevocation = certificate }
                    .buttonStyle(SecondaryButtonStyle())
                    .tint(PX.Color.alert)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func revoke(_ certificate: Certificate) {
        // TODO — px_revoke_certificate, à brancher avec device-account.
        LogBridge.shared.note("révocation demandée : \(certificate.fingerprint)")
    }
}

private struct Row: View {
    let label: String, value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack(spacing: PX.Space.tight) {
            Text(label)
                .font(PX.Font.mono(10.5))
                .foregroundStyle(PX.Color.inkFaint)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(PX.Font.mono(11.5))
                .foregroundStyle(PX.Color.inkMuted)
        }
    }
}
