#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS4="${DS4_DIR:-$ROOT/external/ds4}"
PATCH="$ROOT/patches/ds4-think-max.patch"

if [[ ! -f "$DS4/ds4.c" ]]; then
  echo "error: $DS4/ds4.c missing — run git submodule update --init --recursive" >&2
  exit 1
fi

if grep -q 'Beyond maximum' "$DS4/ds4.c"; then
  echo "ds4 THINK_MAX patch already applied"
  exit 0
fi

git -C "$DS4" apply "$PATCH"
echo "applied $PATCH"
