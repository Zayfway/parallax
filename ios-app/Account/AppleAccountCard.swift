import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
// CONNEXION AU COMPTE APPLE
//
// Le seul écran de l'app qui demande un mot de passe. Il doit donc dire, sans
// qu'on ait à cliquer sur quoi que ce soit, où va ce mot de passe : nulle part.
// Seules les données d'attestation transitent par le relais anisette.
//
// L'état est une machine à quatre positions — repos, en cours, code demandé,
// connecté — et chaque transition est animée avec le vocabulaire de PX.Motion.
// Rien ne saute : `acquire` pour le moment où la session s'établit, `settle`
// pour le reste.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class AppleAccountModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case awaitingCode
        case connected(String)

        var isBusy: Bool { self == .connecting || self == .awaitingCode }
    }

    /// État de la liste de certificats. Séparé de `Phase` : le compte peut être
    /// connecté alors que la liste est en cours de chargement ou en échec, et
    /// l'écran Certificats doit pouvoir distinguer les trois.
    enum Certificates: Equatable {
        case idle
        case loading
        case loaded([FFI.Certificate])
        case failed(String)
    }

    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published private(set) var phase: Phase = .idle
    @Published var failure: String?

    @Published private(set) var certificates: Certificates = .idle
    /// Numéro de série en cours de révocation, pour n'immobiliser que sa carte.
    @Published private(set) var revoking: String?

    /// Session `PxSignSession` détenue par Rust. Reste privée : l'écran
    /// Certificats passe par ce modèle plutôt que d'ouvrir une seconde
    /// connexion, donc personne d'autre n'a besoin du pointeur.
    private var session: OpaquePointer?

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// La session n'est **pas** libérée ici. En Swift 6 un `deinit` est
    /// nonisolated et ne peut pas lire une propriété non-`Sendable` de la
    /// classe. Ce n'est pas une fuite en pratique : le modèle vit aussi
    /// longtemps que l'app, et le seul cas où une session est remplacée — une
    /// reconnexion — libère l'ancienne dans `finishSignIn`.
    deinit { TwoFactorBridge.reset() }

    // MARK: - Connexion

    func signIn(anisette: String) {
        guard !email.isEmpty, !password.isEmpty else { return }
        withAnimation(PX.Motion.settle) {
            phase = .connecting
            failure = nil
        }

        let email = email, password = password
        let storage = URL.documentsDirectory.appending(path: "account").path

        // Appel C bloquant : jamais dans une Task. `px_apple_signin` attend le
        // réseau Apple, puis le sémaphore 2FA — donc potentiellement des
        // minutes. Le pool coopératif n'a qu'un thread par cœur.
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(
                atPath: storage, withIntermediateDirectories: true
            )

            let handle: OpaquePointer? = email.withCString { e in
                password.withCString { p in
                    anisette.withCString { a in
                        storage.withCString { s in
                            px_apple_signin(e, p, a, s, TwoFactorBridge.entry)
                        }
                    }
                }
            }

            let detail = FFI.lastError
            Task { @MainActor in self.finishSignIn(handle, account: email, detail: detail) }
        }
    }

    private func finishSignIn(_ handle: OpaquePointer?, account: String, detail: String?) {
        code = ""

        guard let handle else {
            withAnimation(PX.Motion.settle) {
                phase = .idle
                failure = detail ?? "Connexion refusée."
            }
            return
        }

        // Une reconnexion remplace la session : libérer l'ancienne, sinon Rust
        // garde son runtime tokio et sa session développeur pour rien.
        if let previous = session { px_sign_session_free(previous) }
        session = handle

        withAnimation(PX.Motion.acquire) { phase = .connected(account) }
        password = ""
        certificates = .idle
        LogBridge.shared.note("compte Apple connecté")
    }

    // MARK: - Certificats

    /// Charge la liste. Sans effet tant qu'aucune session n'est ouverte : c'est
    /// l'écran qui invite à se connecter, pas une erreur à afficher.
    func loadCertificates() async {
        guard let session else { return }
        if case .loading = certificates { return }

        withAnimation(PX.Motion.settle) { certificates = .loading }

        do {
            let list = try await onBackground { try FFI.certificates(session: session) }
            withAnimation(PX.Motion.settle) { certificates = .loaded(list) }
            LogBridge.shared.note("\(list.count) certificat(s) de développement")
        } catch {
            withAnimation(PX.Motion.settle) {
                certificates = .failed(error.localizedDescription)
            }
        }
    }

    /// Révoque, puis recharge — la liste rendue par Apple fait foi, pas notre
    /// idée de ce qu'elle devrait contenir après coup.
    func revoke(_ certificate: FFI.Certificate) async {
        guard let session, revoking == nil else { return }
        let serial = certificate.serialNumber
        guard !serial.isEmpty else {
            withAnimation(PX.Motion.settle) {
                certificates = .failed("Ce certificat n'a pas de numéro de série : Apple ne permet pas de le révoquer.")
            }
            return
        }

        withAnimation(PX.Motion.settle) { revoking = serial }
        defer { withAnimation(PX.Motion.settle) { revoking = nil } }

        do {
            try await onBackground { try FFI.revokeCertificate(session: session, serial: serial) }
            LogBridge.shared.note("certificat \(serial) révoqué")
            await loadCertificates()
        } catch {
            withAnimation(PX.Motion.settle) {
                certificates = .failed(error.localizedDescription)
            }
        }
    }

    /// Sort l'appel bloquant du pool coopératif, sur le modèle de
    /// `PairingController.start()`.
    private func onBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try work()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Appelé par le pont quand Rust réclame le code — depuis un thread de fond.
    func requestCode() {
        withAnimation(PX.Motion.settle) { phase = .awaitingCode }
    }

    func submitCode() {
        let entered = code
        withAnimation(PX.Motion.settle) { phase = .connecting }
        TwoFactorBridge.supply(entered)
    }

    func cancelCode() {
        withAnimation(PX.Motion.settle) { phase = .connecting }
        TwoFactorBridge.supply(nil)
    }
}

// MARK: - Pont 2FA

/// Le callback C ne capture rien et **bloque** le thread Rust jusqu'à la
/// saisie. D'où le sémaphore : Rust attend, l'interface demande, l'utilisateur
/// tape, le sémaphore libère. La chaîne rendue doit survivre à l'appel, elle
/// est donc conservée ici et libérée à la demande suivante.
enum TwoFactorBridge {

    nonisolated(unsafe) private static var buffer: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var entered: String?
    private static let gate = DispatchSemaphore(value: 0)

    static let entry: PxTwoFactorCallback = { () -> UnsafePointer<CChar>? in
        DispatchQueue.main.async { NotificationCenter.default.post(name: .twoFactorRequested, object: nil) }
        gate.wait()

        buffer?.deallocate()
        buffer = nil

        guard let entered, !entered.isEmpty else { return nil }
        let bytes = Array(entered.utf8CString)
        let allocation = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        allocation.update(from: bytes, count: bytes.count)
        buffer = allocation
        return UnsafePointer(allocation)
    }

    static func supply(_ code: String?) {
        entered = code
        gate.signal()
    }

    static func reset() {
        buffer?.deallocate()
        buffer = nil
    }
}

extension Notification.Name {
    static let twoFactorRequested = Notification.Name("px.twoFactorRequested")
}

// MARK: - Vue

struct AppleAccountCard: View {

    /// Le modèle vient de l'environnement, pas d'un `@StateObject` local : la
    /// session Apple est unique, et l'écran Certificats s'appuie sur la même.
    @EnvironmentObject private var model: AppleAccountModel
    @AppStorage("anisetteURL") private var anisette = "https://ani.sidestore.io"
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: PX.Space.base) {

            header
                .appear(0, shown)

            switch model.phase {
            case .connected(let account):
                connected(account)
                    .appear(1, shown)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .opacity
                    ))

            default:
                form
                    .appear(1, shown)
                    .transition(.opacity)
            }

            if let failure = model.failure {
                Text(failure)
                    .font(PX.Font.body(13))
                    .foregroundStyle(PX.Color.alert)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(PX.Space.base)
        .glassCard(emphasis: true)
        .animation(PX.Motion.settle, value: model.phase)
        .animation(PX.Motion.settle, value: model.failure)
        .onAppear { shown = true }
        .onReceive(NotificationCenter.default.publisher(for: .twoFactorRequested)) { _ in
            model.requestCode()
        }
        .sheet(isPresented: .constant(model.phase == .awaitingCode)) {
            codeSheet
                .presentationDetents([.height(320)])
                .presentationBackground(PX.Color.abyss)
                .interactiveDismissDisabled()
        }
    }

    // MARK: Morceaux

    private var header: some View {
        HStack {
            SectionLabel("Compte Apple")
            Spacer()
            switch model.phase {
            case .connected:
                Tag("Connecté", color: PX.Color.verdant, icon: "checkmark.seal.fill")
            case .connecting, .awaitingCode:
                Tag("En cours", color: PX.Color.azimuth, icon: "arrow.triangle.2.circlepath")
            case .idle:
                Tag("Hors ligne", color: PX.Color.inkFaint, icon: "person.slash")
            }
        }
    }

    private var form: some View {
        VStack(spacing: PX.Space.snug) {
            TextField("", text: $model.email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .field("Identifiant Apple")

            SecureField("", text: $model.password)
                .field("Mot de passe")

            Text("Ton mot de passe ne quitte pas l'appareil. Seules les données d'attestation passent par le relais anisette.")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.signIn(anisette: anisette)
            } label: {
                HStack(spacing: PX.Space.tight) {
                    if model.phase.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                    }
                    Text(model.phase.isBusy ? "Connexion…" : "Se connecter")
                }
            }
            .buttonStyle(ProminentButtonStyle(
                enabled: !model.phase.isBusy && !model.email.isEmpty && !model.password.isEmpty
            ))
            .disabled(model.phase.isBusy || model.email.isEmpty || model.password.isEmpty)
        }
    }

    private func connected(_ account: String) -> some View {
        HStack(spacing: PX.Space.snug) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(PX.Color.verdant)

            VStack(alignment: .leading, spacing: 2) {
                Text(account)
                    .font(PX.Font.mono(13, .semibold))
                    .foregroundStyle(PX.Color.ink)
                    .lineLimit(1)
                Text("Session développeur ouverte")
                    .font(PX.Font.body(12))
                    .foregroundStyle(PX.Color.inkMuted)
            }
            Spacer()
        }
        .padding(.vertical, PX.Space.hair)
    }

    private var codeSheet: some View {
        VStack(spacing: PX.Space.loose) {
            VStack(spacing: PX.Space.tight) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(PX.Color.azimuth)
                Text("Validation en deux étapes")
                    .font(PX.Font.display(20, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text("Saisis le code à six chiffres affiché sur tes appareils Apple.")
                    .font(PX.Font.body(13))
                    .foregroundStyle(PX.Color.inkMuted)
                    .multilineTextAlignment(.center)
            }

            TextField("", text: $model.code)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(PX.Font.mono(28, .bold))
                .tracking(8)
                .onChange(of: model.code) { _, new in
                    model.code = String(new.filter(\.isNumber).prefix(6))
                }
                .field("Code", mono: true)

            VStack(spacing: PX.Space.tight) {
                Button("Valider") { model.submitCode() }
                    .buttonStyle(ProminentButtonStyle(enabled: model.code.count == 6))
                    .disabled(model.code.count != 6)

                Button("Annuler") { model.cancelCode() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(PX.Space.loose)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PX.Color.canvas)
    }
}
