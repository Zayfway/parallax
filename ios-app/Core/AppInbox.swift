import SwiftUI

/// Boîte de transfert entre l'onglet **Sources** et l'onglet **Installer**.
///
/// Sources est un navigateur : il ne signe ni n'installe rien lui-même. Toute la
/// mécanique délicate — compte Apple, certificat importé, injection de tweaks —
/// vit dans l'Installeur, et n'a aucune raison d'être dupliquée. Quand on touche
/// « Installer » sur une app d'une source, on dépose ici son URL et son nom ;
/// `RootView` bascule sur l'Installeur, qui se pré-remplit et laisse l'utilisateur
/// choisir sa méthode de signature. Un seul chemin d'installation, pas deux à
/// maintenir en parallèle.
@MainActor
final class InstallInbox: ObservableObject {

    struct Request: Equatable {
        /// URL distante à télécharger (venue de Sources), ou `nil`.
        var url: String? = nil
        /// Fichier IPA local déjà présent (venu de l'Atelier), ou `nil`.
        var localPath: String? = nil
        let name: String
    }

    /// Dernière demande déposée. `RootView` l'observe pour basculer d'onglet ;
    /// l'Installeur l'observe pour se pré-remplir puis la consomme.
    @Published var pending: Request?

    /// Une app d'une source : URL distante.
    func install(url: String, name: String) {
        pending = Request(url: url, name: name)
    }

    /// Un IPA inspecté dans l'Atelier : fichier déjà local.
    func installLocal(path: String, name: String) {
        pending = Request(localPath: path, name: name)
    }

    /// L'Installeur appelle ceci une fois la demande absorbée, pour qu'un retour
    /// ultérieur sur l'onglet ne la rejoue pas.
    func consume() {
        pending = nil
    }
}
