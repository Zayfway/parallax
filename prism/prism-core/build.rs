// Génère include/prism.h via cbindgen à chaque compilation : l'en-tête ne peut
// pas diverger de la surface Rust. Identique à Parallax, chemin renommé.
fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let out = std::path::Path::new(&crate_dir).join("include/prism.h");
    std::fs::create_dir_all(out.parent().unwrap()).ok();
    if let Ok(bindings) = cbindgen::generate(&crate_dir) {
        bindings.write_to_file(&out);
    }
    println!("cargo:rerun-if-changed=src");
}
