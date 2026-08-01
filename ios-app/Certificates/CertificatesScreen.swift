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
/// **Aucun quota n'est affiché.** La limite de trois vaut pour les comptes
/// gratuits, pas pour les comptes payants, et `list_ios_certs` ne renvoie pas
/// le plafond applicable. Annoncer un chiffre qu'on ne tient pas d'Apple serait
/// faux une fois sur deux ; on montre le décompte, et rien de plus.
///
/// Révoquer casse les apps déjà signées avec le certificat — l'avertissement
/// est donc dans la confirmation, pas en note de bas de page.
struct CertificatesScreen: View {

    @EnvironmentObject private var location: LocationEngine
    @EnvironmentObject private var account: AppleAccountModel

    @State private var pendingRevocation: FFI.Certificate?
    @State private var shown = false

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

                    AppleAccountCard()
                        .appear(1, shown)

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
        return account.revoking != nil
    }

    // MARK: - Contenu

    @ViewBuilder
    private var content: some View {
        if !account.isConnected {
            notice(
                icon: "person.crop.circle.badge.questionmark",
                title: "Compte non connecté",
                detail: "Connecte-toi ci-dessus pour lire les certificats de ton équipe.",
                tint: PX.Color.inkFaint
            )
            .appear(2, shown)
        } else {
            switch account.certificates {
            case .idle, .loading:
                loading.appear(2, shown)

            case .failed(let message):
                VStack(spacing: PX.Space.snug) {
                    notice(
                        icon: "exclamationmark.triangle",
                        title: "Lecture impossible",
                        detail: message,
                        tint: PX.Color.alert
                    )
                    Button("Réessayer") { Task { await account.loadCertificates() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .appear(2, shown)

            case .loaded(let list) where list.isEmpty:
                notice(
                    icon: "checkmark.seal",
                    title: "Aucun certificat",
                    detail: "Apple en créera un à la première signature.",
                    tint: PX.Color.inkFaint
                )
                .appear(2, shown)

            case .loaded(let list):
                // Un seul paramètre de fermeture : la décomposition d'un tuple
                // en deux arguments ne passe pas le vérificateur de types.
                ForEach(Array(list.enumerated()), id: \.element.id) { pair in
                    card(pair.element).appear(pair.offset + 2, shown)
                }
            }
        }
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

    private func notice(
        icon: String, title: String, detail: String, tint: Color
    ) -> some View {
        VStack(spacing: PX.Space.tight) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(tint)
            Text(title)
                .font(PX.Font.display(15, .semibold))
                .foregroundStyle(PX.Color.ink)
            Text(detail)
                .font(PX.Font.body(12.5))
                .foregroundStyle(PX.Color.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PX.Space.wide)
        .padding(.horizontal, PX.Space.base)
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
