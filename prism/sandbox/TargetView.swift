import SwiftUI

struct TargetView: View {
    @StateObject private var s = Slots()

    var body: some View {
        NavigationStack {
            List {
                Section("Entiers") {
                    row("i32 · pièces", String(s.dispI32), s.addr(s.i32)) { s.i32.pointee += Int32($0); s.sync() }
                    row("i16 · gemmes", String(s.dispI16), s.addr(s.i16)) { s.i16.pointee = Int16(clamping: Int(s.i16.pointee) + $0); s.sync() }
                    row("i64 · score", String(s.dispI64), s.addr(s.i64)) { s.i64.pointee += Int64($0); s.sync() }
                    row("u8 · niveau", String(s.dispU8), s.addr(s.u8)) { s.u8.pointee = UInt8(clamping: Int(s.u8.pointee) + $0); s.sync() }
                }
                Section("Flottants") {
                    row("float · vie", String(format: "%.2f", s.dispF32), s.addr(s.f32)) { s.f32.pointee += Float($0); s.sync() }
                    row("double · argent", String(format: "%.2f", s.dispF64), s.addr(s.f64)) { s.f64.pointee += Double($0); s.sync() }
                }
                Section {
                    Button {
                        s.randomize()
                    } label: {
                        Label("Randomiser tout (test recherche floue)", systemImage: "dice")
                    }
                } footer: {
                    Text("Injecte l'agent Prism dans cette app, ouvre la pilule, choisis le type, scanne une de ces valeurs, édite-la — elle change ici en direct (relecture toutes les 0,15 s). Les adresses ci-dessus doivent correspondre à celles trouvées par Prism.")
                }
            }
            .navigationTitle("Cible Prism")
            .monospacedDigit()
        }
    }

    private func row(_ name: String, _ value: String, _ addr: UInt64, _ change: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(value).font(.title3.weight(.bold).monospaced()).foregroundStyle(.tint)
            }
            Text(String(format: "0x%010llX", addr)).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([-10, -1, 1, 10], id: \.self) { d in
                    Button(d > 0 ? "+\(d)" : "\(d)") { change(d) }
                        .buttonStyle(.bordered).controlSize(.small).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 3)
    }
}
