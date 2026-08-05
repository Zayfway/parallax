#!/bin/sh
# Compile prism-core en PrismFFI.xcframework (device + simulateur).
#
#   ./build-prism.sh                → agent-link (défaut)
#   ./build-prism.sh ""             → stub, sans réseau, PR_ERR_NOT_BUILT partout
#   ./build-prism.sh full           → agent-link + static-macho (jalon 2)
#
# Noms re-namespacés vs Parallax : CRATE, OUT, header. Ne réutilise RIEN de
# build-rust.sh (qui ne produit que le crate Parallax).
set -e

CRATE=prism_core
OUT=PrismFFI.xcframework
FEATURES="${1-agent-link}"
FLAGS=""
[ -n "$FEATURES" ] && FLAGS="--features $FEATURES"

cd "$(dirname "$0")/prism-core"

echo "→ device      ${FEATURES:-(stub)}"
cargo build --release --target aarch64-apple-ios $FLAGS
echo "→ simulateur  ${FEATURES:-(stub)}"
cargo build --release --target aarch64-apple-ios-sim $FLAGS

# build.rs génère include/prism.h via cbindgen à chaque compilation.
test -f include/prism.h || { echo "✗ prism.h non généré (cbindgen)"; exit 1; }

cd ..
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library prism-core/target/aarch64-apple-ios/release/lib${CRATE}.a     -headers prism-core/include \
  -library prism-core/target/aarch64-apple-ios-sim/release/lib${CRATE}.a -headers prism-core/include \
  -output "$OUT"

echo "✓ $OUT  (profil : ${FEATURES:-stub})"
