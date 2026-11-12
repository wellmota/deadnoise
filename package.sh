#!/bin/bash
# Gera dist/DeadNoise-<versão>.zip (app + driver + instruções) para anexar a um Release do GitHub.
# Sem Developer ID e notarização, quem baixar precisa liberar o app no Gatekeeper ou compilar do código.
set -euo pipefail
cd "$(dirname "$0")"

# Assinatura ad-hoc: o pacote público não leva o certificado pessoal de quem empacota.
export SIGN_IDENTITY=-
./build.sh
./Driver/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
STAGE=$(mktemp -d)
mkdir -p dist "$STAGE/DeadNoise"
cp -R build/DeadNoise.app build/VolMixAudio.driver README.md LICENSE "$STAGE/DeadNoise/"
OUT="dist/DeadNoise-$VERSION.zip"
/bin/rm -f "$OUT"
ditto -c -k --keepParent "$STAGE/DeadNoise" "$OUT"
/bin/rm -rf "$STAGE"
echo "Gerado: $PWD/$OUT"
shasum -a 256 "$OUT"
