#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
swift test
"$ROOT/Scripts/build_app.sh" debug
