#!/bin/bash
# Gera dist/DeadNoise-<versão>.zip (app + driver + Instalar.command) para anexar a um Release do GitHub.
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
cp -R build/DeadNoise.app build/VolMixAudio.driver README.md LICENSE Resources/dist/Instalar.command "$STAGE/DeadNoise/"
OUT="dist/DeadNoise-$VERSION.zip"
/bin/rm -f "$OUT" dist/DeadNoise.zip
ditto -c -k --keepParent "$STAGE/DeadNoise" "$OUT"
/bin/rm -rf "$STAGE"
# Cópia com nome fixo: é o arquivo que o botão de download do site aponta (releases/latest/download/DeadNoise.zip).
cp "$OUT" dist/DeadNoise.zip
echo "Gerado: $PWD/$OUT e dist/DeadNoise.zip"
shasum -a 256 "$OUT"
