#!/bin/bash
# Gera o instalador oficial: dist/DeadNoise.pkg, assinado com Developer ID e notarizado pela Apple.
# Quem baixa dá dois cliques, segue o Instalador do macOS e pronto: sem Terminal e sem aviso do Gatekeeper.
#
# Pré-requisitos (uma vez só, exigem o Apple Developer Program):
#   1. Certificados "Developer ID Application" e "Developer ID Installer" nas Chaves
#      (Xcode > Ajustes > Contas > Gerenciar Certificados > +).
#   2. Credenciais de notarização guardadas nas Chaves com o nome "deadnoise":
#        xcrun notarytool store-credentials deadnoise --apple-id SEU_APPLE_ID --team-id SEU_TEAM_ID
#      (pede uma senha de app criada em account.apple.com > Início de Sessão e Segurança).
#
# Uso: ./release.sh          -> assina, notariza e grampeia
#      ./release.sh --local  -> monta o .pkg sem assinar, só para inspecionar a estrutura
set -euo pipefail
cd "$(dirname "$0")"

LOCAL=0; [[ "${1:-}" == "--local" ]] && LOCAL=1
PROFILE="${NOTARY_PROFILE:-deadnoise}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)

identity() { security find-identity -v 2>/dev/null | grep -m1 "$1" | sed -E 's/.*"(.+)"/\1/' || true; }
APP_ID=$(identity "Developer ID Application")
PKG_ID=$(identity "Developer ID Installer")

if [[ $LOCAL == 0 ]]; then
  [[ -n "$APP_ID" ]] || { echo "Falta o certificado 'Developer ID Application' nas Chaves (veja o topo deste arquivo)."; exit 1; }
  [[ -n "$PKG_ID" ]] || { echo "Falta o certificado 'Developer ID Installer' nas Chaves (veja o topo deste arquivo)."; exit 1; }
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || { echo "Faltam as credenciais de notarização '$PROFILE' (veja o topo deste arquivo)."; exit 1; }
fi

# 1. Binários universais (Apple Silicon + Intel).
swift build -c release --arch arm64 --arch x86_64
STAGE=$(mktemp -d)
ROOT="$STAGE/root"
APP="$ROOT/Applications/DeadNoise.app"
DRIVER="$ROOT/Library/Audio/Plug-Ins/HAL/VolMixAudio.driver"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DRIVER/Contents/MacOS"
cp .build/apple/Products/Release/VolMix "$APP/Contents/MacOS/DeadNoise"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
clang -O2 -Wall -Wno-unused-parameter -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 -bundle \
  -o "$DRIVER/Contents/MacOS/VolMixAudio" Driver/VolMixAudio.c -framework CoreAudio -framework CoreFoundation

# 2. Assinatura com hardened runtime e carimbo de tempo (exigências da notarização).
if [[ $LOCAL == 0 ]]; then
  codesign --force --options runtime --timestamp --sign "$APP_ID" "$DRIVER"
  codesign --force --options runtime --timestamp --entitlements Resources/DeadNoise.entitlements --sign "$APP_ID" "$APP"
else
  codesign --force --sign - "$DRIVER"
  codesign --force --options runtime --entitlements Resources/DeadNoise.entitlements --sign - "$APP"
fi

# 3. Pacote. Sem "relocação": o Instalador sempre grava em /Applications, mesmo que exista outra cópia do app no disco.
pkgbuild --analyze --root "$ROOT" "$STAGE/component.plist" >/dev/null
/usr/bin/python3 - "$STAGE/component.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    bundles = plistlib.load(f)
for bundle in bundles:
    bundle["BundleIsRelocatable"] = False
with open(path, "wb") as f:
    plistlib.dump(bundles, f)
PY
pkgbuild --root "$ROOT" --component-plist "$STAGE/component.plist" --scripts Resources/pkg/scripts \
  --identifier com.wellingtonmota.volmix.pkg --version "$VERSION" --install-location / "$STAGE/component.pkg" >/dev/null

mkdir -p dist
OUT=dist/DeadNoise.pkg
/bin/rm -f "$OUT"
if [[ $LOCAL == 1 ]]; then
  productbuild --package "$STAGE/component.pkg" "$OUT" >/dev/null
  /bin/rm -rf "$STAGE"
  echo "Gerado sem assinatura (só para inspeção): $PWD/$OUT"
  exit 0
fi
productbuild --package "$STAGE/component.pkg" --sign "$PKG_ID" --timestamp "$OUT" >/dev/null
/bin/rm -rf "$STAGE"

# 4. Notarização e grampo do tíquete (assim o pacote é aceito mesmo offline).
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"
spctl -a -vvv -t install "$OUT"
echo "Pronto: $PWD/$OUT (versão $VERSION)"
shasum -a 256 "$OUT"
