#!/usr/bin/env bash
# Compila lo que la app de iPhone necesita del motor compartido de Orchard:
#   1. qjsc (el compilador de QuickJS) para este Mac, del mismo QuickJS que va en la app,
#   2. el proveedor de YouTube y el generador de tokens, empaquetados y pasados a bytecode,
#   3. el extractor del player (Rust) como biblioteca estática para iPhone.
# Es lo mismo que hace mobile/android/app/build.gradle, pero para iOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/ios/build"
mkdir -p "$OUT/bundles" "$OUT/rust" "$OUT/host"

echo "==> QuickJS: compilador qjsc del host"
cmake -S "$ROOT/third_party/quickjs" -B "$OUT/host/qjs" -DCMAKE_BUILD_TYPE=Release -DQJS_BUILD_LIBC=OFF >/dev/null
cmake --build "$OUT/host/qjs" --target qjsc -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
QJSC="$OUT/host/qjs/qjsc"

echo "==> Proveedor de YouTube (JavaScript)"
(
  cd "$ROOT/providers/youtube"
  npm ci --no-audit --no-fund
  npm run --silent build:runtime -- --outfile="$OUT/bundles/youtube-provider.js"
  npm run --silent build:po-minter -- --outfile="$OUT/bundles/youtube-po-minter.js"
)

echo "==> Bytecode de QuickJS"
(
  cd "$OUT/bundles"
  "$QJSC" -b -C -n youtube-provider.js -o youtube-provider.qjc youtube-provider.js
  "$QJSC" -b -C -n youtube-po-minter.js -o youtube-po-minter.qjc youtube-po-minter.js
)

echo "==> Extractor del player (Rust) para iPhone"
rustup target add aarch64-apple-ios >/dev/null
IPHONEOS_DEPLOYMENT_TARGET=16.0 cargo rustc \
  --manifest-path "$ROOT/Cargo.toml" \
  -p orchard-youtube-extractor --release --lib --crate-type staticlib \
  --target aarch64-apple-ios --target-dir "$OUT/cargo"
cp "$OUT/cargo/aarch64-apple-ios/release/liborchard_youtube_extractor.a" "$OUT/rust/"

ls -la "$OUT/bundles"/*.qjc "$OUT/rust"/*.a
echo "Listo."
