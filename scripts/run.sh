#!/bin/bash
# Build and launch (or relaunch) the pet.
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x ClawdPet 2>/dev/null || true
./scripts/build.sh
open dist/ClawdPet.app "$@"
