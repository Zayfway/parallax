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
    /// La liste RSD est repliée par défaut (l'afficher entière alourdit l'écran).
    @State private var servicesExpanded = false
    /// Diagnostic appareil (batterie, modèle, iOS) via le tunnel.
    @State private var deviceInfo: DeviceInfo?
    /// Journal exporté en fichier, pour la feuille de partage.
    @State private var logShare: ShareItem?

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
                    ScreenHeader("Réglages",
                                 "Ce que l'appareil déclare, et ce que le cœur natif journalise.")
                        .appear(0, shown)

                    statusBanner
                        .appear(1, shown)

                    if let deviceInfo {
                        deviceCard(deviceInfo).appear(2, shown)
                    }

                    if !connection.services.isEmpty {
                        servicesCard.appear(2, shown)
                    }
                    buildCard.appear(2, shown)
                    anisetteCard.appear(3, shown)
                    networkCard.appear(4, shown)
                    consoleCard.appear(5, shown)
                    aboutCard.appear(6, shown)
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear { shown = true }
        .animation(PX.Motion.settle, value: connection.tunnelState)
        .animation(PX.Motion.acquire, value: connection.services.count)
        .task { interfaces = DeviceConnection.activeInterfaces() }
        .task(id: connection.services.count) { await loadDevice() }
        .sheet(item: $logShare) { item in ActivityView(items: [item.url]) }
    }

    /// Écrit le journal dans un fichier et ouvre la feuille de partage.
    private func shareLog() {
        let url = URL.temporaryDirectory.appending(path: "parallax-journal.txt")
        try? log.joined.data(using: .utf8)?.write(to: url)
        logShare = ShareItem(url: url)
    }

    /// Charge le diagnostic si le lien est déjà établi (sans le forcer ici).
    private func loadDevice() async {
        guard let tunnel = connection.tunnelPointer, deviceInfo == nil else { return }
        let info = await withCheckedContinuation { (c: CheckedContinuation<DeviceInfo?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: FFI.deviceInfo(tunnel: tunnel)) }
        }
        if let info { withAnimation(PX.Motion.settle) { deviceInfo = info } }
    }

    /// Carte diagnostic : nom, modèle, iOS, batterie.
    private func deviceCard(_ info: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name.isEmpty ? "Appareil" : info.name)
                        .font(PX.Font.display(16, .semibold))
                        .foregroundStyle(PX.Color.ink)
                    Text("\(info.model) · iOS \(info.iosVersion) (\(info.build))")
                        .font(PX.Font.mono(11))
                        .foregroundStyle(PX.Color.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: PX.Space.tight)
                if info.battery >= 0 {
                    HStack(spacing: 5) {
                        Image(systemName: batteryIcon(info.battery))
                            .font(.system(size: 14, weight: .semibold))
                        Text(info.batteryText)
                            .font(PX.Font.mono(13, .semibold))
                    }
                    .foregroundStyle(batteryTint(info.battery))
                }
            }

            if info.battery >= 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PX.Color.night.opacity(0.55))
                        Capsule().fill(batteryTint(info.battery))
                            .frame(width: geo.size.width * CGFloat(info.battery) / 100)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<10: return "battery.0"
        case ..<50: return "battery.25"
        default:    return "battery.100"
        }
    }

    /// Vert au-dessus de 20 %, rouge en dessous. Jamais d'ambre (réservée au spoof).
    private func batteryTint(_ level: Int) -> Color {
        level <= 20 ? PX.Color.alert : PX.Color.verdant
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
            // En-tête cliquable : la liste RSD est **repliée par défaut**. En
            // afficher des dizaines d'un coup alourdit le rendu ; on ne la
            // déroule qu'à la demande.
            Button {
                withAnimation(PX.Motion.settle) { servicesExpanded.toggle() }
            } label: {
                HStack {
                    SectionLabel("Services RSD")
                    Spacer()
                    Tag("\(connection.services.count)", color: PX.Color.verdant,
                        icon: "checkmark.circle.fill")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PX.Color.inkFaint)
                        .rotationEffect(.degrees(servicesExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if servicesExpanded {
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
                .padding(.top, 2)
            }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    /// Le seul élément coloré, comme sur les trois autres écrans.
    private var statusBanner: some View {
        HStack(spacing: PX.Space.snug) {
            IconTile(system: phase.icon, tint: phase.tint)

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

    /// « À propos » : version de l'app, dépôt, licence.
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("À propos")

            HStack {
                Text("Parallax")
                    .font(PX.Font.display(15, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Spacer()
                Text(appVersion)
                    .font(PX.Font.mono(11.5))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Text("Sideloading d'IPA et spoofing GPS, entièrement sur l'appareil, sans ordinateur.")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(PX.Color.horizon)

            Link(destination: URL(string: "https://github.com/Zayfway/parallax")!) {
                HStack(spacing: PX.Space.tight) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Code source sur GitHub")
                        .font(PX.Font.display(13.5, .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(PX.Color.azimuth)
            }

            Text("Source-available. Licence : voir le dépôt.")
                .font(PX.Font.body(11))
                .foregroundStyle(PX.Color.inkFaint)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "v\(v) (\(b))"
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
            HStack(spacing: PX.Space.snug) {
                SectionLabel("Journal (\(log.lines.count))")
                Spacer()
                Button("Copier") { UIPasteboard.general.string = log.joined }
                    .font(PX.Font.display(12, .medium))
                Button("Partager") { shareLog() }
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
