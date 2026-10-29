#!/usr/bin/env bash
# Prepara um workdir novo para esta tarefa a partir do commit fixado.
# Uso: setup.sh <workdir>     (idempotente: apaga e recria o workdir)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)" || exit 2
# shellcheck source=../../lib/common.sh
source "$here/../../lib/common.sh"
[ $# -eq 1 ] || { echo "uso: $0 <workdir>" >&2; exit 2; }
prepare_workdir "$here" "$1"
