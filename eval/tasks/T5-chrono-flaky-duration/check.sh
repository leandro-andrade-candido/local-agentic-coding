#!/usr/bin/env bash
# Verificações ocultas desta tarefa (o agente nunca vê este diretório).
# Uso: check.sh <workdir> [--out checks.json] [--log check.log] [--baseline SHA]
# Saída: 0 passou, 1 falhou, 3 aguarda nota do gabarito, 2 erro de infraestrutura.
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$here/../../lib/check.py" "$here" "$@"
