// Vocabulaire d'animation nommé par INTENTION, pas par courbe. On ne choisit
// qu'entre quatre gestes. Une seule animation mémorable — `acquire`, réservée
// aux aboutissements (ici : l'écriture qui prend). Tout le reste « se contente
// de ne pas sauter ». Multiplier les effets fait basculer une interface du côté
// généré.

import SwiftUI

extension PR {
    enum Motion {
        /// Doigt : bouton, segment, bascule.
        static let tap = Animation.spring(response: 0.28, dampingFraction: 0.72)
        /// Apparition / changement d'un panneau.
        static let settle = Animation.spring(response: 0.5, dampingFraction: 0.82)
        /// LE moment orchestré — l'écriture qui prend, le candidat qui se verrouille.
        static let acquire = Animation.spring(response: 0.62, dampingFraction: 0.58)
        /// État persistant vivant (pastille qui respire).
        static let breathe = Animation.easeInOut(duration: 2.2).repeatForever(autoreverses: true)
        /// Cascade : 45 ms par élément.
        static func stagger(_ index: Int) -> Animation { settle.delay(Double(index) * 0.045) }
    }
}
