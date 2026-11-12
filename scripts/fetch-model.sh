#!/usr/bin/env bash
# Downloads a model listed in models.tsv to $MODELS_DIR, from a pinned Hugging Face
# revision, with resume and size and SHA-256 verification before putting the
# file in its final place. An invalid partial file is discarded and downloaded once more.
# Usage: scripts/fetch-model.sh <alias>   (aliases in models.tsv)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/versions.env"
MODELS_TSV="${MODELS_TSV:-$ROOT/models.tsv}"

name="${1:?usage: $0 <alias> (see models.tsv)}"
line="$(awk -F'\t' -v a="$name" '$1 == a' "$MODELS_TSV")"
[ -n "$line" ] || { echo "unknown alias: $name" >&2; exit 1; }
IFS=$'\t' read -r _ repo rev file bytes sha _ <<<"$line"

mkdir -p "$MODELS_DIR"
dest="$MODELS_DIR/$file"
part="$dest.part"

verify() { # file
  local size; size=$(stat -c %s "$1")
  [ "$size" = "$bytes" ] || { echo "unexpected size for $1: $size (expected $bytes)" >&2; return 1; }
  echo "$sha  $1" | sha256sum -c --quiet - && echo "ok: $1 ($bytes bytes, sha256 matches)"
}

if [ -f "$dest" ]; then
  verify "$dest"; exit
fi

exec 9>"$part.lock"
flock -n 9 || { echo "download of $file is already in progress" >&2; exit 1; }

for attempt in 1 2; do
  if [ ! -f "$part" ] || [ "$(stat -c %s "$part")" -lt "$bytes" ]; then
    curl -fL --retry 5 --retry-delay 5 -C - -o "$part" \
      "https://huggingface.co/$repo/resolve/$rev/$file"
  fi
  if verify "$part"; then
    mv "$part" "$dest"
    rm -f "$part.lock"
    echo "installed: $dest"
    exit 0
  fi
  echo "invalid partial file (attempt $attempt); discarding" >&2
  rm -f "$part"
done
exit 1
