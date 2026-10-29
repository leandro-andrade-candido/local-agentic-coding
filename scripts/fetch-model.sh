#!/usr/bin/env bash
# Baixa um modelo listado em models.tsv para $MODELS_DIR, de uma revisão fixa do
# Hugging Face, com retomada e verificação de tamanho e SHA-256 antes de colocar o
# arquivo no lugar final. Um parcial inválido é descartado e baixado de novo uma vez.
# Uso: scripts/fetch-model.sh <alias>   (aliases em models.tsv)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/versions.env"
MODELS_TSV="${MODELS_TSV:-$ROOT/models.tsv}"

name="${1:?uso: $0 <alias> (ver models.tsv)}"
line="$(awk -F'\t' -v a="$name" '$1 == a' "$MODELS_TSV")"
[ -n "$line" ] || { echo "alias desconhecido: $name" >&2; exit 1; }
IFS=$'\t' read -r _ repo rev file bytes sha _ <<<"$line"

mkdir -p "$MODELS_DIR"
dest="$MODELS_DIR/$file"
part="$dest.part"

verify() { # arquivo
  local size; size=$(stat -c %s "$1")
  [ "$size" = "$bytes" ] || { echo "tamanho inesperado em $1: $size (esperado $bytes)" >&2; return 1; }
  echo "$sha  $1" | sha256sum -c --quiet - && echo "ok: $1 ($bytes bytes, sha256 confere)"
}

if [ -f "$dest" ]; then
  verify "$dest"; exit
fi

exec 9>"$part.lock"
flock -n 9 || { echo "download de $file já está em andamento" >&2; exit 1; }

for attempt in 1 2; do
  if [ ! -f "$part" ] || [ "$(stat -c %s "$part")" -lt "$bytes" ]; then
    curl -fL --retry 5 --retry-delay 5 -C - -o "$part" \
      "https://huggingface.co/$repo/resolve/$rev/$file"
  fi
  if verify "$part"; then
    mv "$part" "$dest"
    rm -f "$part.lock"
    echo "instalado: $dest"
    exit 0
  fi
  echo "parcial inválido (tentativa $attempt); descartando" >&2
  rm -f "$part"
done
exit 1
