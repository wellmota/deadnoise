#!/bin/bash
# Coloca o Sparkle.framework (atualização automática) dentro do app e assina as peças de dentro para fora,
# como pede a documentação do Sparkle para apps fora da App Store. Rodar ANTES de assinar o app.
# Uso: ./embed-sparkle.sh caminho/DeadNoise.app "identidade de assinatura ou -" [--release]
#      --release acrescenta hardened runtime e carimbo de tempo (exigências da notarização).
set -euo pipefail
cd "$(dirname "$0")"
APP="$1"; IDENTITY="$2"; MODE="${3:-}"

SRC=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[[ -d "$SRC" ]] || swift package resolve >/dev/null
mkdir -p "$APP/Contents/Frameworks"
/bin/rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SRC" "$APP/Contents/Frameworks/Sparkle.framework"

FLAGS=(--force --sign "$IDENTITY" --options runtime)
[[ "$MODE" == "--release" ]] && FLAGS+=(--timestamp)
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign "${FLAGS[@]}" "$FW/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$FW/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$FW"
