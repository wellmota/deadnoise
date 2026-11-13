#!/bin/bash
# Gera os dois downloads oficiais, assinados com Developer ID e notarizados pela Apple:
#   dist/DeadNoise.dmg  imagem de disco com a arte de "arraste para Aplicativos"; o app instala o
#                       microfone virtual sozinho na primeira vez (pede a senha).
#   dist/DeadNoise.pkg  instalador do macOS que já coloca app e driver no lugar.
#
# Pré-requisitos (uma vez só, exigem o Apple Developer Program):
#   1. Certificados "Developer ID Application" e "Developer ID Installer" nas Chaves
#      (Xcode > Ajustes > Contas > Gerenciar Certificados > +).
#   2. Credenciais de notarização guardadas nas Chaves com o nome "deadnoise":
#        xcrun notarytool store-credentials deadnoise --apple-id SEU_APPLE_ID --team-id SEU_TEAM_ID
#      (pede uma senha de app criada em account.apple.com > Início de Sessão e Segurança).
#
# Também gera dist/appcast.xml, a lista de versões que o app consulta para se atualizar (Sparkle).
# Ela vai como arquivo do release do GitHub; o app lê sempre a do release mais recente.
# Notas da versão: release-notes/<versão>.md (obrigatório; aparece na janela de atualização e no GitHub).
# Publicar depois: ./publish.sh
#
# Uso: ./release.sh          -> assina, notariza e grampeia
#      ./release.sh --local  -> monta os dois sem assinar, só para inspecionar a estrutura
#
# O .dmg é montado com o dmgbuild (Python), instalado sozinho em .build/dmgvenv na primeira vez.
set -euo pipefail
cd "$(dirname "$0")"

LOCAL=0; [[ "${1:-}" == "--local" ]] && LOCAL=1
PROFILE="${NOTARY_PROFILE:-deadnoise}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)
NOTES="release-notes/$VERSION.md"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-deadnoise}"
REPO_URL=https://github.com/wellmota/deadnoise

[[ -s "$NOTES" ]] || { echo "Faltam as notas da versão em $NOTES."; exit 1; }
# O Sparkle compara CFBundleVersion: ele precisa crescer a cada versão, senão ninguém recebe a atualização.
PUBLISHED=$(curl -fsSL "$FEED" 2>/dev/null | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1 || true)
if [[ -n "$PUBLISHED" && "$BUILD" -le "$PUBLISHED" ]]; then
  echo "CFBundleVersion ($BUILD) precisa ser maior que o da versão publicada ($PUBLISHED). Aumente em Resources/Info.plist."
  exit 1
fi

identity() { security find-identity -v 2>/dev/null | grep -m1 "$1" | sed -E 's/.*"(.+)"/\1/' || true; }
APP_ID=$(identity "Developer ID Application")
PKG_ID=$(identity "Developer ID Installer")

swift package resolve >/dev/null
if [[ $LOCAL == 0 ]]; then
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 \
    || { echo "Falta a chave de assinatura das atualizações '$SPARKLE_ACCOUNT' nas Chaves (veja o README)."; exit 1; }
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
#    O driver é assinado primeiro e uma cópia vai dentro do app, que sabe instalá-lo sozinho (caminho do .dmg).
if [[ $LOCAL == 0 ]]; then
  codesign --force --options runtime --timestamp --sign "$APP_ID" "$DRIVER"
  cp -R "$DRIVER" "$APP/Contents/Resources/VolMixAudio.driver"
  ./embed-sparkle.sh "$APP" "$APP_ID" --release
  codesign --force --options runtime --timestamp --entitlements Resources/DeadNoise.entitlements --sign "$APP_ID" "$APP"
else
  codesign --force --sign - "$DRIVER"
  cp -R "$DRIVER" "$APP/Contents/Resources/VolMixAudio.driver"
  ./embed-sparkle.sh "$APP" -
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
DMG=dist/DeadNoise.dmg
/bin/rm -f "$OUT" "$DMG"

# 4. Imagem de disco com a arte de fundo.
[[ -x .build/dmgvenv/bin/dmgbuild ]] || { python3 -m venv .build/dmgvenv && .build/dmgvenv/bin/pip install -q dmgbuild; }
.build/dmgvenv/bin/dmgbuild -s Resources/dmg/settings.py -D app="$APP" -D icon=Resources/AppIcon.icns \
  -D background=Resources/dmg/background.tiff "DeadNoise" "$DMG" >/dev/null

if [[ $LOCAL == 1 ]]; then
  productbuild --package "$STAGE/component.pkg" "$OUT" >/dev/null
  /bin/rm -rf "$STAGE"
  echo "Gerados sem assinatura (só para inspeção): $PWD/$OUT e $PWD/$DMG"
  exit 0
fi
productbuild --package "$STAGE/component.pkg" --sign "$PKG_ID" --timestamp "$OUT" >/dev/null
codesign --force --timestamp --sign "$APP_ID" "$DMG"
/bin/rm -rf "$STAGE"

# 5. Notarização e grampo do tíquete (assim os arquivos são aceitos mesmo offline).
for FILE in "$OUT" "$DMG"; do
  xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$FILE"
done
spctl -a -vvv -t install "$OUT"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# 6. Appcast: aponta para o .dmg deste release (URL fixa da versão), com a assinatura EdDSA do arquivo
#    já grampeado. O próprio appcast também é assinado (SURequireSignedFeed no Info.plist).
ENCLOSURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
NOTES_TEXT=$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")
APPCAST=dist/appcast.xml
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>DeadNoise</title>
    <link>$REPO_URL</link>
    <language>pt-BR</language>
    <item>
      <title>DeadNoise $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[$NOTES_TEXT]]></description>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/DeadNoise.dmg" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
"$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --disable-signing-warning "$APPCAST" >/dev/null
xmllint --noout "$APPCAST"

echo "Pronto: $PWD/$OUT, $PWD/$DMG e $PWD/$APPCAST (versão $VERSION, build $BUILD)"
shasum -a 256 "$OUT" "$DMG"
echo "Para publicar: ./publish.sh"
