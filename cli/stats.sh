#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-public}"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory not found: $TARGET_DIR" >&2
  exit 1
fi

count=$(find "$TARGET_DIR" -type f -name '*.avif' | wc -l | tr -d ' ')
size=$(du -sh "$TARGET_DIR" | awk '{print $1}')

echo "$TARGET_DIR: $size"
echo ".avif: $count"
