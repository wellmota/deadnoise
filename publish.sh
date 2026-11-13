#!/bin/bash
# Publica no GitHub o que o ./release.sh gerou: .dmg, .pkg e appcast.xml num release vX.Y.Z.
# Assim que o release sai, os apps instalados encontram a versão nova (o appcast é lido do release mais recente)
# e o botão de download do site passa a entregar os arquivos novos.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
TAG="v$VERSION"
SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
ACCOUNT="${SPARKLE_ACCOUNT:-deadnoise}"
FILES=(dist/DeadNoise.dmg dist/DeadNoise.pkg dist/appcast.xml)

fail() { echo "$1"; exit 1; }
for f in "${FILES[@]}"; do [[ -f "$f" ]] || fail "Falta $f. Rode ./release.sh antes."; done
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "Há mudanças sem commit. Faça o commit antes de publicar."
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || fail "O commit atual não está no GitHub. Rode git push antes."
gh release view "$TAG" >/dev/null 2>&1 && fail "O release $TAG já existe."

# O que vai ser publicado precisa bater com esta versão e estar assinado.
grep -q "<sparkle:version>$BUILD</sparkle:version>" dist/appcast.xml || fail "dist/appcast.xml não é do build $BUILD. Rode ./release.sh de novo."
grep -q "releases/download/$TAG/DeadNoise.dmg" dist/appcast.xml || fail "dist/appcast.xml não aponta para $TAG."
"$SIGN_UPDATE" --account "$ACCOUNT" --verify dist/appcast.xml >/dev/null || fail "A assinatura do appcast não confere."
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' dist/appcast.xml)
"$SIGN_UPDATE" --account "$ACCOUNT" --verify dist/DeadNoise.dmg "$SIG" >/dev/null || fail "O .dmg mudou depois de assinado. Rode ./release.sh de novo."
xcrun stapler validate -q dist/DeadNoise.dmg || fail "O .dmg não está notarizado."

gh release create "$TAG" "${FILES[@]}" --target "$(git rev-parse HEAD)" \
  --title "DeadNoise $VERSION" --notes-file "release-notes/$VERSION.md"
echo "Publicado: $TAG. Os apps instalados vão encontrar a atualização na próxima procura (até 24 h)."
