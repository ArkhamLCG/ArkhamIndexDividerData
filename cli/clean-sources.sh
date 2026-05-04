#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-public/images}"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory not found: $TARGET_DIR" >&2
  exit 1
fi

# Recursively delete source images inside TARGET_DIR.
find "$TARGET_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print0 \
  | xargs -0 rm -f
