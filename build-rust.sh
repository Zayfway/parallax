#!/usr/bin/env bash
# Compile rust-core en ParallaxFFI.xcframework (device + simulateur).
#
#   ./build-rust.sh                      → stub, compile en ~30 s, sans réseau
#   ./build-rust.sh device-location      → module GPS réel
#   ./build-rust.sh device               → tout (attends-toi à corriger des signatures)
set -euo pipefail

CRATE=parallax_ffi
OUT=ParallaxFFI.xcframework
FEATURES="${1:-}"
FLAGS=""
[ -n "$FEATURES" ] && FLAGS="--features $FEATURES"

cd "$(dirname "$0")/rust-core"

echo "→ device      ${FEATURES:-(stub)}"
cargo build --release --target aarch64-apple-ios $FLAGS
echo "→ simulateur  ${FEATURES:-(stub)}"
cargo build --release --target aarch64-apple-ios-sim $FLAGS

# build.rs génère include/parallax.h via cbindgen à chaque compilation :
# l'en-tête ne peut pas diverger de la surface Rust.
test -f include/parallax.h || { echo "✗ en-tête non généré"; exit 1; }

cd ..
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/lib${CRATE}.a \
  -headers rust-core/include \
  -library rust-core/target/aarch64-apple-ios-sim/release/lib${CRATE}.a \
  -headers rust-core/include \
  -output "$OUT"

echo "✓ $OUT  (profil : ${FEATURES:-stub})"
