import SwiftUI
import CoreLocation
import CoreImage.CIFilterBuiltins
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
// PARTAGE D'UN POINT
//
// Une position simulée n'a de valeur que si on peut la rejouer — la garder pour
// soi, ou l'envoyer à quelqu'un. On encode donc le point dans un lien
// `parallax://locate?lat=…&lon=…` : copiable, partageable, et surtout affiché en
// **QR code**. Un ami scanne, son Parallax s'ouvre et propose de poser le point.
//
// Le QR est rendu sur fond blanc — un code sur verre sombre ne se scanne pas.
// C'est le seul carré blanc de l'app, et c'est justifié : il s'adresse à
// l'appareil d'en face, pas à l'œil.
// ═══════════════════════════════════════════════════════════════════════════

/// Enveloppe `Identifiable` pour présenter un point via `.sheet(item:)` et pour
/// le router par le moteur (`Equatable` par identité, `CLLocationCoordinate2D`
/// ne l'étant pas).
struct SharePoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    static func == (a: SharePoint, b: SharePoint) -> Bool { a.id == b.id }
}

extension Notification.Name {
    /// Postée quand un lien `parallax://locate` est ouvert : la carte vise le
    /// point et propose de le poser.
    static let locateRequest = Notification.Name("px.locateRequest")
}

/// Encode / décode le lien de partage d'un point.
enum LocationLink {
    static func string(for c: CLLocationCoordinate2D) -> String {
        String(format: "parallax://locate?lat=%.6f&lon=%.6f", c.latitude, c.longitude)
    }

    static func coordinate(from url: URL) -> CLLocationCoordinate2D? {
        guard url.scheme?.lowercased() == "parallax",
              url.host?.lowercased() == "locate",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        var lat: Double?
        var lon: Double?
        for item in items {
            switch item.name.lowercased() {
            case "lat": lat = item.value.flatMap(Double.init)
            case "lon", "lng": lon = item.value.flatMap(Double.init)
            default: break
            }
        }
        guard let lat, let lon,
              CLLocationCoordinate2DIsValid(.init(latitude: lat, longitude: lon))
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct LocationShareSheet: View {
    let coordinate: CLLocationCoordinate2D

    private var link: String { LocationLink.string(for: coordinate) }

    var body: some View {
        VStack(spacing: PX.Space.loose) {
            // Poignée maison : l'indicateur système barrait le titre.
            Capsule()
                .fill(PX.Color.horizon)
                .frame(width: 38, height: 5)
                .padding(.top, PX.Space.snug)

            VStack(spacing: 6) {
                Text("Partager le point")
                    .font(PX.Font.display(20, .semibold))
                    .foregroundStyle(PX.Color.ink)
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(PX.Font.mono(13, .medium))
                    .foregroundStyle(PX.Color.inkMuted)
            }

            if let qr = qrImage(link) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 208, height: 208)
                    .padding(PX.Space.base)
                    .background(
                        RoundedRectangle(cornerRadius: PX.Radius.card, style: .continuous)
                            .fill(.white)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            }

            HStack(spacing: PX.Space.snug) {
                Button {
                    UIPasteboard.general.string = link
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copier le lien", systemImage: "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())

                if let url = URL(string: link) {
                    ShareLink(item: url) {
                        Label("Partager", systemImage: "square.and.arrow.up")
                            .font(PX.Font.display(14, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Capsule(style: .continuous).fill(PX.Color.azimuth))
                    }
                }
            }

            Text("Scanne ce code, ou ouvre le lien sur un autre iPhone équipé de Parallax : il proposera de poser ce point.")
                .font(PX.Font.body(12))
                .foregroundStyle(PX.Color.inkFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PX.Space.loose)
        .padding(.bottom, PX.Space.loose)
        .frame(maxWidth: .infinity)
    }

    /// Rend le QR à partir du lien. `interpolation(.none)` conservé à
    /// l'affichage pour des modules nets.
    private func qrImage(_ string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard
            let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
            let cg = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
