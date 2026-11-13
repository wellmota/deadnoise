#!/bin/bash
# Uso: ./build.sh           -> gera build/DeadNoise.app
#      ./build.sh install   -> gera e copia para /Applications (ou ~/Applications) e abre
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/DeadNoise.app
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VolMix "$APP/Contents/MacOS/DeadNoise"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# O app leva o driver dentro, para poder instalar o microfone virtual sozinho.
./Driver/build.sh >/dev/null
cp -R build/VolMixAudio.driver "$APP/Contents/Resources/VolMixAudio.driver"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Assinar com um certificado estável faz a permissão de áudio sobreviver aos rebuilds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.+)"/\1/' || true)}"
./embed-sparkle.sh "$APP" "${IDENTITY:--}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Assinado com: ${IDENTITY:-ad-hoc}"
echo "Gerado: $PWD/$APP"

if [[ "${1:-}" == "install" ]]; then
  DEST=/Applications
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x VolMix 2>/dev/null || true
  pkill -x DeadNoise 2>/dev/null || true
  # O app se chamava VolMix: remove a cópia antiga para não ficarem dois com o mesmo identificador.
  /bin/rm -rf "$DEST/VolMix.app" "$DEST/DeadNoise.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/DeadNoise.app"
  echo "Instalado em $DEST/DeadNoise.app"
fi
