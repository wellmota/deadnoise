#!/bin/bash
# Confere a tradução: pede ao compilador do Swift a lista de textos que o app mostra e verifica
# se cada um tem tradução em inglês (e se nenhuma tradução sobrou de um texto que não existe mais).
# Uso: ./check-l10n.sh   (sai com erro se faltar tradução; o release.sh roda antes de gerar a versão)
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap '/bin/rm -rf "$OUT"' EXIT
swift build --scratch-path .build/l10n -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
plutil -convert json -o "$OUT/en.json" Resources/Localization/en.lproj/Localizable.strings
/usr/bin/python3 -I - "$OUT" <<'PY'
import glob, json, re, sys
out = sys.argv[1]
keys = set()
for f in glob.glob(out + "/*.stringsdata"):
    for entries in json.load(open(f))["tables"].values():
        keys.update(e["key"] for e in entries)
en = json.load(open(out + "/en.json"))
spec = re.compile(r"%(?:lld|ld|d|@|f)")
missing = sorted(keys - en.keys())
unused = sorted(en.keys() - keys)
bad = [k for k in keys & en.keys() if spec.findall(k) != spec.findall(en[k])]
for k in missing: print("FALTA TRADUÇÃO:", k)
for k in unused: print("tradução sem uso (pode apagar):", k)
for k in bad: print("FORMATO DIFERENTE (%@, %lld…):", k)
print(f"{len(keys)} textos, {len(keys & en.keys())} traduzidos")
sys.exit(1 if missing or bad else 0)
PY
