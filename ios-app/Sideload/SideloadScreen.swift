import SwiftUI

/// Onglet Installer.
///
/// Trois changements par rapport à la capture d'origine, chacun pour une raison :
///
/// 1. L'action principale est **ancrée** au-dessus de la barre d'onglets via
///    `safeAreaInset`, et non posée en fin de pile où elle finit dessous.
/// 2. Le bandeau LocalDevVPN nomme l'action (« Ouvrir LocalDevVPN ») plutôt que
///    l'état (« Tunnel désactivé ») : un symptôme ne dit pas quoi faire.
/// 3. Le sélecteur d'app et le canal Stable/Nightly sont deux segments empilés
///    plutôt qu'un menu déroulant qui recouvre le contrôle voisin à l'ouverture.
struct SideloadScreen: View {

    @EnvironmentObject private var connection: DeviceConnection
    @EnvironmentObject private var location: LocationEngine
    @EnvironmentObject private var account: AppleAccountModel

    @State private var email = ""
    @State private var password = ""
    @State private var target: InstallTarget = .sideStore
    @State private var channel: Channel = .stable
    @State private var installing = false
    @State private var progress: InstallProgress?
    @State private var failure: String?
    @State private var installed: String?
    /// Permet de corriger une adresse devenue fausse sans reconstruire l'app.
    @AppStorage("ipaSourceOverride") private var sourceOverride: String = ""

    enum InstallTarget: String, CaseIterable {
        case sideStore = "SideStore"
        case withLiveContainer = "+ LiveContainer"

        /// Les variantes correspondent aux `SpecialApp` qu'isideload sait
        /// reconnaître : `SideStore` et `SideStoreLc`. C'est Rust qui confirmera
        /// laquelle il a réellement détectée dans l'IPA signé.
        func url(for channel: Channel) -> String {
            switch (self, channel) {
            case (.sideStore, .stable):
                "https://github.com/SideStore/SideStore/releases/latest/download/SideStore.ipa"
            case (.sideStore, .nightly):
                "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa"
            case (.withLiveContainer, .stable):
                "https://github.com/SideStore/SideStore/releases/latest/download/SideStore-LiveContainer.ipa"
            case (.withLiveContainer, .nightly):
                "https://github.com/SideStore/SideStore/releases/download/nightly/SideStore-LiveContainer.ipa"
            }
        }
    }
    enum Channel: String, CaseIterable { case stable = "Stable", nightly = "Nightly" }

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    InstrumentStrip(
                        latitude: location.currentFix?.latitude,
                        longitude: location.currentFix?.longitude,
                        sessionLabel: connection.tunnelState.shortLabel,
                        live: location.state == .simulating
                    )

                    header

                    accountCard
                    targetCard

                    if installing || progress != nil {
                        progressCard
                    }

                    if let installed {
                        resultCard(installed)
                    }

                    if let failure {
                        failureCard(failure)
                    }

                    if !connection.tunnelState.isConnected {
                        tunnelCard
                    }
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, PX.Space.wide)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .installProgress)) { note in
            guard let update = note.object as? InstallProgress else { return }
            withAnimation(PX.Motion.settle) { progress = update }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await install() }
            } label: {
                Text(installing ? "Installation…" : "Installer \(target.rawValue)")
            }
            .buttonStyle(ProminentButtonStyle(enabled: canInstall))
            .disabled(!canInstall)
            .padding(.horizontal, PX.Space.base)
            .padding(.bottom, PX.Space.tight)
            .background(
                LinearGradient(colors: [PX.Color.night.opacity(0), PX.Color.night],
                               startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .allowsHitTesting(false),
                alignment: .bottom
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Installer")
                .font(PX.Font.display(30, .heavy))
                .foregroundStyle(PX.Color.ink)
            Text("Signé sur cet appareil, avec ton compte.")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PX.Space.tight)
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Compte Apple")

            TextField("", text: $email, prompt: Text("nom@icloud.com")
                .foregroundStyle(PX.Color.inkFaint))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .field("Identifiant", mono: true)

            SecureField("", text: $password, prompt: Text("••••••••")
                .foregroundStyle(PX.Color.inkFaint))
                .textContentType(.password)
                .field("Mot de passe")

            // La revendication de confidentialité est posée là où l'utilisateur
            // décide, pas enterrée dans un écran « À propos ». Et elle est
            // exacte : le relais Anisette est nommé, parce qu'il existe.
            Label {
                Text("Le mot de passe reste sur l'appareil. L'attestation Apple passe par un relais Anisette, configurable dans les réglages.")
            } icon: {
                Image(systemName: "lock.shield")
            }
            .font(PX.Font.body(11.5))
            .foregroundStyle(PX.Color.inkFaint)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    /// Une seule barre, pervenche : opération en cours. Jamais d'ambre, qui ne
    /// signifie que « position simulée active ».
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.tight) {
            HStack {
                SectionLabel("Installation")
                Spacer()
                Text("\(progress?.percent ?? 0) %")
                    .font(PX.Font.mono(11, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(PX.Color.azimuth)
                    .contentTransition(.numericText())
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PX.Color.night.opacity(0.55))
                    Capsule()
                        .fill(PX.Color.azimuth)
                        .frame(width: geometry.size.width * CGFloat(progress?.percent ?? 0) / 100)
                }
            }
            .frame(height: 4)

            Text(progress?.label ?? "Préparation")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
        }
        .padding(PX.Space.base)
        .glassCard()
        .animation(PX.Motion.settle, value: progress)
    }

    private func resultCard(_ name: String) -> some View {
        HStack(spacing: PX.Space.snug) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 24))
                .foregroundStyle(PX.Color.verdant)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) installé")
                    .font(PX.Font.display(14.5, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text("Cherche-le sur ton écran d'accueil.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private func failureCard(_ message: String) -> some View {
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

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            SectionLabel("Application")
            SegmentedRow(selection: $target, options: InstallTarget.allCases) { $0.rawValue }
            SegmentedRow(selection: $channel, options: Channel.allCases) { $0.rawValue }
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    private var tunnelCard: some View {
        HStack(alignment: .top, spacing: PX.Space.snug) {
            Image(systemName: "shield.lefthalf.filled.slash")
                .font(.system(size: 17))
                .foregroundStyle(PX.Color.alert)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ouvre LocalDevVPN")
                    .font(PX.Font.display(14, .semibold))
                    .foregroundStyle(PX.Color.alert)
                Text("L'installation passe par son tunnel local.")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer()

            Link(destination: URL(string: "localdevvpn://")!) {
                Text("Ouvrir")
                    .font(PX.Font.display(13, .semibold))
                    .foregroundStyle(PX.Color.alert)
                    .padding(.horizontal, PX.Space.snug)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(PX.Color.alert.opacity(0.16)))
            }
        }
        .padding(PX.Space.base)
        .background(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .fill(PX.Color.alert.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                .strokeBorder(PX.Color.alert.opacity(0.28), lineWidth: 1)
        )
    }

    /// Les trois conditions réelles, dans l'ordre où l'utilisateur les remplit :
    /// compte connecté, lien établi, identité de l'appareil connue. Les champs
    /// de mot de passe locaux ne conditionnent plus rien — la session vient du
    /// modèle partagé.
    private var canInstall: Bool {
        account.isConnected && connection.tunnelPointer != nil && !installing
    }

    /// Enchaîne le tout : le lien doit être vivant, le compte connecté, et
    /// l'identité de l'appareil connue — sans UDID, Apple refuse le profil de
    /// provisionnement avec l'erreur 8220.
    private func install() async {
        guard !installing else { return }

        guard let device = FFI.pairedDevice(besidePairingFile: PairingStore.fileURL) else {
            failure = "Identité de l'appareil inconnue. Refais le jumelage : l'UDID y est relevé une seule fois."
            return
        }

        installing = true
        progress = InstallProgress(percent: 0, label: "Préparation")
        failure = nil
        defer { installing = false }

        do {
            // Le lien d'abord : sans lui, ni transfert ni installation.
            try await connection.connect()
            guard let tunnel = connection.tunnelPointer else {
                failure = "Lien indisponible. Passe par l'onglet Jumelage."
                return
            }
            guard let session = account.sessionPointer else {
                failure = "Connecte-toi à ton compte Apple avant d'installer."
                return
            }

            let ipa = try await download(target: target, channel: channel)
            let special = try await onBackground {
                try FFI.installIPA(
                    session: session, tunnel: tunnel,
                    ipaPath: ipa.path, device: device
                )
            }
            installed = special.isEmpty ? target.rawValue : special
            LogBridge.shared.note("installation terminée : \(installed ?? "")")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Récupère l'IPA à installer.
    ///
    /// ⚠️ Ces adresses sont les URL publiques usuelles des projets concernés ;
    /// je ne les ai pas vérifiées contre un téléchargement réel. Si l'une
    /// change, elle est surchargeable dans les Réglages plutôt que de figer une
    /// valeur fausse dans le binaire.
    private func download(target: InstallTarget, channel: Channel) async throws -> URL {
        let source = sourceOverride.isEmpty ? target.url(for: channel) : sourceOverride
        guard let url = URL(string: source) else {
            throw InstallError.badSource(source)
        }

        progress = InstallProgress(percent: 0, label: "Téléchargement de \(target.rawValue)")
        let (temporary, response) = try await URLSession.shared.download(from: url)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download(http.statusCode, source)
        }

        // URLSession supprime son fichier temporaire à la sortie du scope ;
        // on le déplace sous un nom stable avant de le confier à Rust.
        let destination = URL.temporaryDirectory
            .appending(path: "\(target.rawValue)-\(channel.rawValue).ipa")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    enum InstallError: LocalizedError {
        case badSource(String)
        case download(Int, String)

        var errorDescription: String? {
            switch self {
            case .badSource(let s): "Adresse de téléchargement invalide : \(s)"
            case .download(let code, let s): "Téléchargement refusé (\(code)) : \(s)"
            }
        }
    }

    /// Sort l'appel bloquant du pool coopératif — l'installation dure des
    /// dizaines de secondes.
    private func onBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Composants partagés
/// Segment maison plutôt que `Picker(.segmented)` : le contrôle système ne
/// laisse pas assez de prise sur le rayon ni sur la police, et le résultat
/// jurerait avec le reste. Le comportement, lui, reste identique.
/// Segment maison plutot que `Picker(.segmented)` : le controle systeme ne
/// laisse pas assez de prise sur le rayon ni sur la police.
///
/// Chaque item est une vue separee. Ce n'est pas de la coquetterie : empiler
/// trois ternaires dans une seule chaine de modificateurs fait exploser le
/// verificateur de types de Swift, qui abandonne avec un message peu clair.
/// Un sous-type par element garde chaque expression courte.
struct SegmentedRow<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                SegmentItem(
                    label: title(option),
                    active: option == selection
                ) {
                    withAnimation(PX.Motion.tap) { selection = option }
                }
            }
        }
        .padding(3)
        .background(segmentBackground)
        .overlay(segmentBorder)
    }

    private var segmentBackground: some View {
        RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
            .fill(PX.Color.night.opacity(0.55))
    }

    private var segmentBorder: some View {
        RoundedRectangle(cornerRadius: PX.Radius.control, style: .continuous)
            .strokeBorder(PX.Color.horizon, lineWidth: 1)
    }
}

private struct SegmentItem: View {
    let label: String
    let active: Bool
    let onTap: () -> Void

    private var weight: Font.Weight { active ? .semibold : .medium }
    private var ink: Color { active ? PX.Color.ink : PX.Color.inkFaint }
    private var fill: Color { active ? PX.Color.strata : .clear }
    private var shade: Color { active ? .black.opacity(0.35) : .clear }

    var body: some View {
        Text(label)
            .font(PX.Font.display(13, weight))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(chip)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: PX.Radius.chip, style: .continuous)
            .fill(fill)
            .shadow(color: shade, radius: 6, y: 2)
    }
}
