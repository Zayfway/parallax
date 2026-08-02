import SwiftUI

/// Réglages et diagnostic.
///
/// Le profil de compilation est affiché en premier, et ce n'est pas un détail :
/// avec le flag `device` désactivé, toutes les fonctions natives renvoient
/// « non compilé ». Sans cette ligne, l'utilisateur passerait une heure à
/// soupçonner son VPN.
///
/// Même grammaire que les trois autres écrans : bande d'instruments, titre en
/// display, un seul élément coloré qui porte l'état, cascade. Le `NavigationStack`
/// et son titre système ont disparu — ils juraient avec le reste, seul cet écran
/// en avait un.
///
/// Le bandeau porte ici l'état du **lien**, parce que c'est la question que se
/// pose quiconque ouvre cet écran : est-ce que l'appareil répond, et sinon où
/// ça coince.
struct SettingsScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @EnvironmentObject private var location: LocationEngine
    @StateObject private var log = LogBridge.shared

    @AppStorage("anisetteURL") private var anisetteURL = "https://ani.sidestore.io"
    @State private var interfaces: [(name: String, address: String)] = []
    @State private var shown = false

    // MARK: - Phase

    enum Phase: Equatable {
        case vpnDown
        case wrongSubnet(String)
        case vpnUp
        case linked(Int)

        var tint: Color {
            switch self {
            case .vpnDown:     PX.Color.alert
            case .wrongSubnet: PX.Color.alert
            case .vpnUp:       PX.Color.azimuth
            case .linked:      PX.Color.verdant
            }
        }

        var label: String {
            switch self {
            case .vpnDown:     "VPN loopback absent"
            case .wrongSubnet: "VPN sur le mauvais sous-réseau"
            case .vpnUp:       "VPN prêt"
            case .linked:      "Lien établi"
            }
        }

        var icon: String {
            switch self {
            case .vpnDown:     "shield.lefthalf.filled.slash"
            case .wrongSubnet: "exclamationmark.triangle.fill"
            case .vpnUp:       "shield.lefthalf.filled"
            case .linked:      "checkmark.seal.fill"
            }
        }

        var detail: String {
            switch self {
            case .vpnDown:
                "ouvre LocalDevVPN et touche Connect — rien ne peut aboutir sans lui"
            case .wrongSubnet(let found):
                "interfaces trouvées : \(found)"
            case .vpnUp:
                "établis le lien dans l'onglet Jumelage"
            case .linked(let count):
                "\(count) services exposés par l'appareil"
            }
        }
    }

    private var phase: Phase {
        if !connection.services.isEmpty { return .linked(connection.services.count) }
        switch connection.tunnelState {
        case .down:                    return .vpnDown
        case .wrongSubnet(let found):  return .wrongSubnet(found)
        case .connecting, .connected:  return .vpnUp
        }
    }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    InstrumentStrip(
                        latitude: location.currentFix?.latitude,
                        longitude: location.currentFix?.longitude,
                        sessionLabel: "\(connection.deviceIP) : \(DeviceConnection.rsdPort)",
                        live: location.state == .simulating
                    )

                    title
                        .appear(0, shown)

                    statusBanner
                        .appear(1, shown)

                    if !connection.services.isEmpty {
                        servicesCard.appear(2, shown)
                    }
                    buildCard.appear(2, shown)
                    anisetteCard.appear(3, shown)
                    networkCard.appear(4, shown)
                    consoleCard.appear(5, shown)
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear { shown = true }
        .animation(PX.Motion.settle, value: connection.tunnelState)
        .animation(PX.Motion.acquire, value: connection.services.count)
        .task { interfaces = DeviceConnection.activeInterfaces() }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Réglages")
                .font(PX.Font.display(30, .heavy))
                .foregroundStyle(PX.Color.ink)
            Text("Ce que l'appareil déclare, et ce que le cœur natif journalise.")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PX.Space.tight)
    }

    /// Ce que l'appareil annonce, mot pour mot. En mono parce que rien ici n'a
    /// été reformulé pour l'humain : ce sont les noms de service et les ports
    /// que RSD a rendus.
    ///
    /// Cette carte vivait sur l'écran Jumelage, où elle s'intercalait entre le
    /// lien établi et l'export du fichier. Sa place est ici : c'est du
    /// diagnostic, pas une étape.
    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack {
                SectionLabel("Services RSD")
                Spacer()
                Tag("\(connection.services.count)", color: PX.Color.verdant,
                    icon: "checkmark.circle.fill")
            }

            ForEach(connection.services.sorted(by: { $0.key < $1.key }), id: \.key) { name, port in
                HStack(alignment: .top, spacing: PX.Space.tight) {
                    Text(name)
                        .font(PX.Font.mono(10.5))
                        .foregroundStyle(PX.Color.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: PX.Space.tight)
                    Text("\(port)")
                        .font(PX.Font.mono(10.5, .semibold))
                        .foregroundStyle(PX.Color.inkFaint)
                }
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    /// Le seul élément coloré, comme sur les trois autres écrans.
    private var statusBanner: some View {
        HStack(spacing: PX.Space.snug) {
            ZStack {
                Circle()
                    .fill(phase.tint.opacity(0.16))
                    .frame(width: 42, height: 42)
                Image(systemName: phase.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(phase.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label)
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text(phase.detail)
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(phase.tint.opacity(0.34), lineWidth: 1)
        )
        .shadow(color: phase.tint.opacity(0.22), radius: 16, y: 6)
        .animation(PX.Motion.settle, value: phase)
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
