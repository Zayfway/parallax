import SwiftUI

/// Onglet Certificats.
///
/// Existe pour une raison précise : quand un compte a consommé ses
/// emplacements de certificat, la signature échoue avec un message Apple
/// opaque, et l'utilisateur n'a aucun moyen de voir ce qui les occupe ni d'en
/// libérer un. C'est la cause d'abandon la plus fréquente sur ce type d'outil.
///
/// L'écran liste donc ce qu'Apple déclare réellement, et permet de révoquer.
///
/// **Le quota vient d'Apple, jamais du code.** La limite de trois vaut pour un
/// compte gratuit et pas pour un compte payant ; l'écrire en dur serait faux
/// une fois sur deux. Apple renseigne `maxActiveCerts` dans le type de
/// certificat — on affiche ce chiffre-là quand il est présent, et le simple
/// décompte quand il ne l'est pas.
///
/// Révoquer casse les apps déjà signées avec le certificat — l'avertissement
/// est donc dans la confirmation, pas en note de bas de page.
///
/// ── MÊME GRAMMAIRE QUE LES DEUX AUTRES ÉCRANS ────────────────────────────
/// Machine à phases explicite, un seul élément coloré — le bandeau — qui porte
/// l'état, entrées en cascade. **Pas de rail** en revanche : ici on ne franchit
/// pas des étapes, on constate un état, et un rail numéroté promettrait une
/// progression qui n'existe pas.
///
/// Le contenu ne redit jamais ce que le bandeau annonce déjà ; il n'offre que
/// ce sur quoi on peut agir.
struct CertificatesScreen: View {

    @EnvironmentObject private var location: LocationEngine
    @EnvironmentObject private var account: AppleAccountModel

    @State private var pendingRevocation: FFI.Certificate?
    @State private var shown = false

    // MARK: - Phase

    /// Même machine explicite que `PairingScreen` et `SideloadScreen`. Ici elle
    /// n'est pas séquentielle — on ne franchit pas des étapes, on constate un
    /// état — d'où un bandeau mais pas de rail : un rail numéroté promettrait
    /// une progression qui n'existe pas.
    enum Phase: Equatable {
        case needsAccount
        case loading
        case working(String)
        case empty
        case listed(Int, Int?)
        case failed(String)

        var tint: Color {
            switch self {
            case .needsAccount:        PX.Color.inkFaint
            case .loading, .working:   PX.Color.azimuth
            case .empty:               PX.Color.inkFaint
            case .listed:              PX.Color.verdant
            case .failed:              PX.Color.alert
            }
        }

        var label: String {
            switch self {
            case .needsAccount: "Compte requis"
            case .loading:      "Lecture"
            case .working:      "Opération en cours"
            case .empty:        "Aucun certificat"
            case .listed:       "Certificats"
            case .failed:       "Échec"
            }
        }

        var icon: String {
            switch self {
            case .needsAccount: "person.crop.circle.badge.exclamationmark"
            case .loading:      "arrow.triangle.2.circlepath"
            case .working:      "hourglass"
            case .empty:        "checkmark.seal"
            case .listed:       "checkmark.seal.fill"
            case .failed:       "exclamationmark.triangle.fill"
            }
        }

        var detail: String {
            switch self {
            case .needsAccount: "connecte-toi ci-dessous pour lire ceux de ton équipe"
            case .loading:      "interrogation d'Apple"
            case .working(let what): what
            case .empty:        "Apple en créera un à la première signature"
            case .listed(let count, let quota):
                if let quota { "\(count) sur \(quota) emplacements déclarés par Apple" }
                else { count == 1 ? "1 certificat de développement" : "\(count) certificats de développement" }
            case .failed:       "voir le détail ci-dessous"
            }
        }
    }

    private var phase: Phase {
        if !account.isConnected { return .needsAccount }
        if account.isCreatingCertificate { return .working("demande d'un certificat à Apple") }
        if let serial = account.revoking { return .working("révocation de \(serial)") }
        switch account.certificates {
        case .idle, .loading:  return .loading
        case .failed(let m):   return .failed(m)
        case .loaded(let list):
            return list.isEmpty ? .empty : .listed(list.count, account.certificateQuota)
        }
    }

    /// Le seul élément qui change de couleur, comme sur les deux autres écrans.
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

    var body: some View {
        ZStack {
            PX.Color.canvas

            ScrollView {
                VStack(spacing: PX.Space.snug) {
                    InstrumentStrip(
                        latitude: location.currentFix?.latitude,
                        longitude: location.currentFix?.longitude,
                        sessionLabel: stripLabel,
                        live: location.state == .simulating
                    )

                    header
                        .appear(0, shown)

                    statusBanner
                        .appear(1, shown)

                    AppleAccountCard()
                        .appear(3, shown)

                    content
                }
                .padding(.horizontal, PX.Space.base)
                .padding(.bottom, 110)
            }
        }
        .onAppear { shown = true }
        .task(id: account.phase) { await account.loadCertificates() }
        .confirmationDialog(
            "Révoquer ce certificat ?",
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: pendingRevocation
        ) { certificate in
            Button("Révoquer", role: .destructive) {
                pendingRevocation = nil
                Task { await account.revoke(certificate) }
            }
            Button("Annuler", role: .cancel) { pendingRevocation = nil }
        } message: { certificate in
            Text(warning(for: certificate))
        }
    }

    // MARK: - En-tête

    private var stripLabel: String {
        guard account.isConnected else { return "hors ligne" }
        switch account.certificates {
        case .idle, .loading:      return "lecture…"
        case .failed:              return "erreur"
        case .loaded(let list):
            // Le quota vient d'Apple (`maxActiveCerts`) ou n'est pas affiché.
            // Rien n'est codé en dur : trois vaut pour un compte gratuit.
            if let quota = account.certificateQuota {
                return "\(list.count) / \(quota) emplacements"
            }
            switch list.count {
            case 0:  return "aucun certificat"
            case 1:  return "1 certificat"
            default: return "\(list.count) certificats"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Certificats")
                    .font(PX.Font.display(30, .heavy))
                    .foregroundStyle(PX.Color.ink)
                Text("Ce que ton compte développeur déclare chez Apple.")
                    .font(PX.Font.body(13))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            Spacer()

            if account.isConnected {
                Button {
                    Task { await account.loadCertificates() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PX.Color.azimuth)
                        .padding(PX.Space.tight)
                        .background(Circle().fill(PX.Color.azimuth.opacity(0.14)))
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PX.Space.tight)
    }

    private var isBusy: Bool {
        if case .loading = account.certificates { return true }
        return account.revoking != nil || account.isCreatingCertificate
    }

    // MARK: - Contenu

    /// Le bandeau porte déjà l'état — compte manquant, liste vide, échec. Le
    /// contenu ne répète donc pas ces messages : il n'offre que ce sur quoi on
    /// peut agir. Redire la même chose deux fois à l'écran, c'est diluer les
    /// deux.
    @ViewBuilder
    private var content: some View {
        if account.isConnected {
            switch account.certificates {
            case .idle, .loading:
                loading.appear(4, shown)

            case .failed:
                Button("Réessayer") { Task { await account.loadCertificates() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .appear(4, shown)

            case .loaded(let list) where list.isEmpty:
                createButton.appear(4, shown)

            case .loaded(let list):
                createButton.appear(4, shown)
                ForEach(Array(list.enumerated()), id: \.element.id) { pair in
                    card(pair.element).appear(pair.offset + 5, shown)
                }
            }
        }
    }

    /// Action principale de l'écran, donc `ProminentButtonStyle` — et il n'y
    /// en a qu'une. Pervenche : opération en cours, jamais l'ambre.
    private var createButton: some View {
        Button {
            Task { await account.createCertificate() }
        } label: {
            HStack(spacing: PX.Space.tight) {
                if account.isCreatingCertificate {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "plus.viewfinder")
                }
                Text(account.isCreatingCertificate
                     ? "Demande à Apple…"
                     : "Générer un certificat")
            }
        }
        .buttonStyle(ProminentButtonStyle(enabled: !isBusy))
        .disabled(isBusy)
    }

    private var loading: some View {
        HStack(spacing: PX.Space.snug) {
            ProgressView().tint(PX.Color.azimuth)
            Text("Lecture chez Apple…")
                .font(PX.Font.body(13))
                .foregroundStyle(PX.Color.inkMuted)
            Spacer()
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    // MARK: - Carte de certificat

    private func card(_ certificate: FFI.Certificate) -> some View {
        VStack(alignment: .leading, spacing: PX.Space.snug) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(certificate.machineName.isEmpty ? "Machine sans nom" : certificate.machineName)
                        .font(PX.Font.display(14.5, .semibold))
                        .foregroundStyle(PX.Color.ink)
                    if !certificate.name.isEmpty {
                        Text(certificate.name)
                            .font(PX.Font.body(11.5))
                            .foregroundStyle(PX.Color.inkFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: PX.Space.tight)
                badge(for: certificate)
            }

            VStack(alignment: .leading, spacing: 3) {
                if !certificate.serialNumber.isEmpty {
                    Row("Série", certificate.serialNumber, mono: true)
                }
                if !certificate.certificateID.isEmpty {
                    Row("ID", certificate.certificateID, mono: true)
                }
                Row("Expire", expiryText(certificate), mono: false)
            }

            Button {
                pendingRevocation = certificate
            } label: {
                if account.revoking == certificate.serialNumber {
                    HStack(spacing: PX.Space.tight) {
                        ProgressView().tint(PX.Color.inkMuted)
                        Text("Révocation…")
                    }
                } else {
                    Text("Révoquer")
                }
            }
            .buttonStyle(SecondaryButtonStyle(tint: PX.Color.alert))
            .disabled(isBusy || certificate.isRevoked || certificate.serialNumber.isEmpty)
            .opacity(certificate.isRevoked || certificate.serialNumber.isEmpty ? 0.4 : 1)
        }
        .padding(PX.Space.base)
        .glassCard()
    }

    /// Vert quand le certificat est celui de cette app et qu'il est valide,
    /// rouge quand il ne signera plus rien, neutre pour une autre machine.
    /// L'ambre n'apparaît nulle part ici : elle ne signifie que « position
    /// simulée active ».
    @ViewBuilder
    private func badge(for certificate: FFI.Certificate) -> some View {
        if certificate.isRevoked {
            Tag("Révoqué", color: PX.Color.alert, icon: "xmark.seal.fill")
        } else if certificate.isExpired {
            Tag("Expiré", color: PX.Color.alert, icon: "clock.badge.exclamationmark.fill")
        } else if certificate.isOurs {
            Tag("Cet appareil", color: PX.Color.verdant, icon: "checkmark.seal.fill")
        } else {
            Tag("Autre machine", color: PX.Color.inkFaint, icon: "desktopcomputer")
        }
    }

    private func expiryText(_ certificate: FFI.Certificate) -> String {
        guard let expiry = certificate.expiry else { return "date inconnue" }
        return expiry.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Confirmation

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRevocation != nil },
            set: { if !$0 { pendingRevocation = nil } }
        )
    }

    /// L'avertissement nomme la conséquence réelle, qui n'est pas la même selon
    /// que le certificat est le nôtre ou celui d'un autre outil.
    private func warning(for certificate: FFI.Certificate) -> String {
        if certificate.isOurs {
            return "C'est le certificat utilisé par Parallax. Les apps qu'il a signées cesseront de s'ouvrir jusqu'à leur resignature, et la prochaine installation en créera un nouveau."
        }
        let machine = certificate.machineName.isEmpty ? "une autre machine" : certificate.machineName
        return "Ce certificat vient de \(machine). Toutes les apps signées avec lui cesseront de s'ouvrir jusqu'à leur resignature."
    }
}

private struct Row: View {
    let label: String, value: String, mono: Bool
    init(_ label: String, _ value: String, mono: Bool) {
        self.label = label; self.value = value; self.mono = mono
    }

    var body: some View {
        HStack(alignment: .top, spacing: PX.Space.tight) {
            Text(label)
                .font(PX.Font.mono(10.5))
                .foregroundStyle(PX.Color.inkFaint)
                .frame(width: 46, alignment: .leading)
            // Mono = valeur machine. Une date rendue lisible pour l'humain
            // passe en rounded, comme le reste du texte adressé à l'utilisateur.
            Text(value)
                .font(mono ? PX.Font.mono(11.5) : PX.Font.body(12))
                .foregroundStyle(PX.Color.inkMuted)
                .textSelection(.enabled)
        }
    }
}
