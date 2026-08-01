import SwiftUI

/// Réglages et diagnostic.
///
/// Le profil de compilation est affiché en premier, et ce n'est pas un détail :
/// avec le flag `device` désactivé, toutes les fonctions natives renvoient
/// « non compilé ». Sans cette ligne, l'utilisateur passerait une heure à
/// soupçonner son VPN.
struct SettingsScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @StateObject private var log = LogBridge.shared

    @AppStorage("anisetteURL") private var anisetteURL = "https://ani.sidestore.io"
    @State private var interfaces: [(name: String, address: String)] = []

    var body: some View {
        NavigationStack {
            ZStack {
                PX.Color.canvas

                ScrollView {
                    VStack(spacing: PX.Space.snug) {
                        buildCard
                        anisetteCard
                        networkCard
                        consoleCard
                    }
                    .padding(PX.Space.base)
                    .padding(.bottom, 90)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { interfaces = DeviceConnection.activeInterfaces() }
    }

    private var buildCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            SectionLabel("Version")
            HStack {
                Text("Cœur natif")
                    .font(PX.Font.body(14))
                    .foregroundStyle(PX.Color.inkMuted)
                Spacer()
                Text(FFI.buildProfile)
                    .font(PX.Font.mono(11.5))
                    .foregroundStyle(FFI.buildProfile.hasPrefix("stub")
                                     ? PX.Color.signal : PX.Color.verdant)
            }
            if FFI.buildProfile.hasPrefix("stub") {
                Text("Compilé sans --features device : l'interface fonctionne, mais aucune opération sur l'appareil n'aboutira.")
                    .font(PX.Font.body(11.5))
                    .foregroundStyle(PX.Color.inkFaint)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var anisetteCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            SectionLabel("Serveur Anisette")

            TextField("", text: $anisetteURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .field("Relais", mono: true)

            // Cette explication est ici parce qu'elle est vraie et que la cacher
            // rendrait la revendication de confidentialité de l'app inexacte.
            Text("L'authentification Apple exige des données d'attestation impossibles à produire sur un iPhone non jailbreaké. Elles transitent par ce relais. Ton mot de passe, lui, ne quitte pas l'appareil.")
                .font(PX.Font.body(11.5))
                .foregroundStyle(PX.Color.inkFaint)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            SectionLabel("Réseau")

            TextField("", text: $connection.deviceIP)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .field("IP de l'appareil", mono: true)

            // Afficher lo0, en0 et ipsec0 ensemble est ce qui permet de
            // comprendre d'un coup d'œil pourquoi un tunnel ne prend pas.
            ForEach(interfaces, id: \.name) { interface in
                HStack {
                    Text(interface.name)
                        .font(PX.Font.mono(11))
                        .foregroundStyle(PX.Color.inkFaint)
                        .frame(width: 62, alignment: .leading)
                    Text(interface.address)
                        .font(PX.Font.mono(11.5))
                        .foregroundStyle(PX.Color.inkMuted)
                    Spacer()
                }
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var consoleCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack {
                SectionLabel("Journal (\(log.lines.count))")
                Spacer()
                Button("Copier") { UIPasteboard.general.string = log.joined }
                    .font(PX.Font.display(12, .medium))
                Button("Vider") { log.clear() }
                    .font(PX.Font.display(12, .medium))
                    .tint(PX.Color.alert)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.lines.suffix(200).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(PX.Font.mono(10))
                            .foregroundStyle(PX.Color.inkMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 240)
            .padding(PX.Space.tight)
            .background(
                RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
                    .fill(PX.Color.night.opacity(0.6))
            )
        }
        .padding(PX.Space.base)
        .glassCard()
    }
}
