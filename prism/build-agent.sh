#!/bin/sh
# Compile le dylib agent injectable, en posant l'install_name attendu par
# l'injection palier 1 (@executable_path/Frameworks/…). L'agent est autonome :
# aucune dépendance Substrate, il se contente d'écouter le loopback.
set -e

cd "$(dirname "$0")/prism-agent"
NAME="@executable_path/Frameworks/libprism_agent.dylib"

echo "→ device"
RUSTFLAGS="-C link-arg=-Wl,-install_name,$NAME" \
  cargo build --release --target aarch64-apple-ios
echo "→ simulateur"
RUSTFLAGS="-C link-arg=-Wl,-install_name,$NAME" \
  cargo build --release --target aarch64-apple-ios-sim

echo "✓ agent : prism-agent/target/aarch64-apple-ios/release/libprism_agent.dylib"
