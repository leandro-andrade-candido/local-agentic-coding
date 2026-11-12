#!/usr/bin/env bash
# Hidden checks for this task (the agent never sees this directory).
# Usage: check.sh <workdir> [--out checks.json] [--log check.log] [--baseline SHA]
# Exit: 0 passed, 1 failed, 3 awaiting rubric grade, 2 infrastructure error.
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$here/../../lib/check.py" "$here" "$@"
