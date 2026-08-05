import SwiftUI

// Chaque valeur vit à une adresse stable sur le tas (malloc via
// UnsafeMutablePointer) — donc scannable et modifiable par l'agent Prism.
// Un timer relit les pointés toutes les 0,15 s et publie pour l'UI : si Prism
// écrit dans la mémoire, l'affichage suit tout seul.
final class Slots: ObservableObject {
    let i32 = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let i16 = UnsafeMutablePointer<Int16>.allocate(capacity: 1)
    let i64 = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    let u8  = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    let f32 = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let f64 = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    @Published var dispI32: Int32 = 0
    @Published var dispI16: Int16 = 0
    @Published var dispI64: Int64 = 0
    @Published var dispU8: UInt8 = 0
    @Published var dispF32: Float = 0
    @Published var dispF64: Double = 0

    private var timer: Timer?

    init() {
        i32.pointee = 100
        i16.pointee = 50
        i64.pointee = 1_000_000
        u8.pointee = 5
        f32.pointee = 3.5
        f64.pointee = 9.99
        sync()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.sync() }
    }

    func sync() {
        dispI32 = i32.pointee; dispI16 = i16.pointee; dispI64 = i64.pointee
        dispU8 = u8.pointee; dispF32 = f32.pointee; dispF64 = f64.pointee
    }

    func randomize() {
        i32.pointee = Int32.random(in: 0...9999)
        i16.pointee = Int16.random(in: 0...999)
        i64.pointee = Int64.random(in: 0...9_999_999)
        u8.pointee = UInt8.random(in: 0...255)
        f32.pointee = Float((Int.random(in: 0...10000))) / 100
        f64.pointee = Double((Int.random(in: 0...100000))) / 100
        sync()
    }

    func addr<T>(_ p: UnsafeMutablePointer<T>) -> UInt64 { UInt64(UInt(bitPattern: p)) }
}
