// Compile l'overlay UIKit (Objective-C) dans le dylib agent, sur cibles Apple.
// cc interroge xcrun pour le bon SDK iOS/simulateur. Les frameworks sont liés
// au cdylib injecté (l'hôte fournit déjà UIKit).
fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("apple") {
        cc::Build::new()
            .file("overlay/PrismOverlay.m")
            .flag("-fobjc-arc")
            .flag_if_supported("-Wno-unused-parameter")
            .flag_if_supported("-Wno-deprecated-declarations")
            .compile("prismoverlay");
        for fw in ["UIKit", "Foundation", "QuartzCore", "CoreGraphics"] {
            println!("cargo:rustc-link-lib=framework={fw}");
        }
    }
    println!("cargo:rerun-if-changed=overlay/PrismOverlay.m");
    println!("cargo:rerun-if-changed=overlay/PrismOverlay.h");
}
