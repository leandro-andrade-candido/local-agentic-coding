#!/usr/bin/env bash
# Installs the llama.cpp build pinned in versions.env into $LLAMA_CPP_PREFIX/<build>
# (binaries + CUDA libraries in the same directory) and points the "current" link at it.
# The active version is always the one in versions.env. To go back to an earlier build, change
# LLAMA_CPP_BUILD and the hashes there and run again: old builds stay on disk,
# so going back downloads nothing.
# Usage: scripts/install-llama-cpp.sh
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
flock -n 9 || { echo "another installation is already in progress" >&2; exit 1; }

fetch() { # file sha256. The final name only exists after it is verified.
  local f="$dl/$1"
  if [ -f "$f" ] && echo "$2  $f" | sha256sum -c --quiet - 2>/dev/null; then return; fi
  rm -f "$f"
  curl -fL --retry 5 -o "$f.part" "$base/$1"
  if ! echo "$2  $f.part" | sha256sum -c --quiet -; then
    rm -f "$f.part"; echo "SHA-256 mismatch: $1" >&2; return 1
  fi
  mv "$f.part" "$f"
}

# The .complete marker is only created after everything is extracted and verified; a directory
# without it is the leftover of an interrupted installation and is redone.
if [ ! -f "$dest/.complete" ]; then
  fetch "$main" "$LLAMA_CPP_SHA256_MAIN"
  fetch "$cudart" "$LLAMA_CPP_SHA256_CUDART"
  tmp="$(mktemp -d "$LLAMA_CPP_PREFIX/.install-XXXX")"
  trap 'rm -rf "$tmp"' EXIT
  tar -xzf "$dl/$main" -C "$tmp" --strip-components=1
  tar -xzf "$dl/$cudart" -C "$tmp" --strip-components=1
  [ -x "$tmp/llama-server" ] || { echo "llama-server missing from the package" >&2; exit 1; }
  chmod 755 "$tmp"
  touch "$tmp/.complete"
  rm -rf "$dest"
  mv -T "$tmp" "$dest"
  trap - EXIT
fi
ln -sfn "$LLAMA_CPP_BUILD" "$LLAMA_CPP_PREFIX/current"
echo "installed: $dest  (current -> $LLAMA_CPP_BUILD)"
