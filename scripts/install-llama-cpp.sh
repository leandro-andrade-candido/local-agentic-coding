#!/usr/bin/env bash
# Instala o build do llama.cpp fixado em versions.env em $LLAMA_CPP_PREFIX/<build>
# (binários + bibliotecas CUDA no mesmo diretório) e aponta o link "current" para ele.
# A versão ativa é sempre a de versions.env. Para voltar a um build anterior, altere
# LLAMA_CPP_BUILD e os hashes lá e rode de novo: builds antigos continuam no disco,
# então a volta não baixa nada.
# Uso: scripts/install-llama-cpp.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/versions.env"

base="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_CPP_BUILD"
main="llama-$LLAMA_CPP_BUILD-bin-$LLAMA_CPP_VARIANT.tar.gz"
cudart="cudart-llama-$LLAMA_CPP_BUILD-bin-$LLAMA_CPP_VARIANT.tar.gz"
dl="$CACHE_DIR/downloads"
dest="$LLAMA_CPP_PREFIX/$LLAMA_CPP_BUILD"
mkdir -p "$dl" "$LLAMA_CPP_PREFIX"

exec 9>"$LLAMA_CPP_PREFIX/.install.lock"
flock -n 9 || { echo "outra instalação já está em andamento" >&2; exit 1; }

fetch() { # arquivo sha256. O nome final só existe depois de conferido.
  local f="$dl/$1"
  if [ -f "$f" ] && echo "$2  $f" | sha256sum -c --quiet - 2>/dev/null; then return; fi
  rm -f "$f"
  curl -fL --retry 5 -o "$f.part" "$base/$1"
  if ! echo "$2  $f.part" | sha256sum -c --quiet -; then
    rm -f "$f.part"; echo "SHA-256 não confere: $1" >&2; return 1
  fi
  mv "$f.part" "$f"
}

# O marcador .complete só é criado depois de tudo extraído e conferido; um diretório
# sem ele é resto de instalação interrompida e é refeito.
if [ ! -f "$dest/.complete" ]; then
  fetch "$main" "$LLAMA_CPP_SHA256_MAIN"
  fetch "$cudart" "$LLAMA_CPP_SHA256_CUDART"
  tmp="$(mktemp -d "$LLAMA_CPP_PREFIX/.install-XXXX")"
  trap 'rm -rf "$tmp"' EXIT
  tar -xzf "$dl/$main" -C "$tmp" --strip-components=1
  tar -xzf "$dl/$cudart" -C "$tmp" --strip-components=1
  [ -x "$tmp/llama-server" ] || { echo "llama-server ausente no pacote" >&2; exit 1; }
  chmod 755 "$tmp"
  touch "$tmp/.complete"
  rm -rf "$dest"
  mv -T "$tmp" "$dest"
  trap - EXIT
fi
ln -sfn "$LLAMA_CPP_BUILD" "$LLAMA_CPP_PREFIX/current"
echo "instalado: $dest  (current -> $LLAMA_CPP_BUILD)"
