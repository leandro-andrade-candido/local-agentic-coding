#!/usr/bin/env bash
# Prepares a fresh workdir for this task from the pinned commit.
# Usage: setup.sh <workdir>     (idempotent: deletes and recreates the workdir)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)" || exit 2
# shellcheck source=../../lib/common.sh
source "$here/../../lib/common.sh"
[ $# -eq 1 ] || { echo "usage: $0 <workdir>" >&2; exit 2; }
prepare_workdir "$here" "$1"
