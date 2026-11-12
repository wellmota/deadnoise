#!/bin/bash
# Driver do microfone virtual do DeadNoise ("DeadNoise Microphone").
# Uso: ./Driver/build.sh            -> gera build/VolMixAudio.driver
#      ./Driver/build.sh install    -> gera, instala em /Library/Audio/Plug-Ins/HAL e reinicia o áudio (pede senha)
#      ./Driver/build.sh uninstall  -> remove o driver e reinicia o áudio (pede senha)
# Reiniciar o áudio interrompe por alguns segundos tudo o que estiver tocando ou em chamada.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Library/Audio/Plug-Ins/HAL/VolMixAudio.driver"

if [[ "${1:-}" == "uninstall" ]]; then
  sudo /bin/rm -rf "$DEST"
  sudo killall coreaudiod
  echo "Driver removido."
  exit 0
fi

OUT=build/VolMixAudio.driver
/bin/rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp Driver/Info.plist "$OUT/Contents/Info.plist"
clang -O2 -Wall -Wno-unused-parameter -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 -bundle \
  -o "$OUT/Contents/MacOS/VolMixAudio" Driver/VolMixAudio.c \
  -framework CoreAudio -framework CoreFoundation

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.+)"/\1/' || true)}"
codesign --force --sign "${IDENTITY:--}" "$OUT"
echo "Assinado com: ${IDENTITY:-ad-hoc}"
echo "Gerado: $PWD/$OUT"

if [[ "${1:-}" == "install" ]]; then
  sudo /bin/rm -rf "$DEST"
  sudo cp -R "$OUT" "$DEST"
  sudo chown -R root:wheel "$DEST"
  sudo killall coreaudiod
  echo "Instalado em $DEST. O microfone “DeadNoise Microphone” aparece em alguns segundos."
fi
