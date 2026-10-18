#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-public/images}"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory not found: $TARGET_DIR" >&2
  exit 1
fi

# Prefer avifenc (handles stills + alpha correctly). Homebrew ffmpeg no longer
# ships libaom-av1, and libsvtav1 cannot write AVIF alpha planes.
if command -v avifenc >/dev/null 2>&1; then
  encode() {
    local in="$1" out="$2"
    # -q 60 ≈ medium quality (similar to former ffmpeg -crf 30)
    # -s 6  = default-ish speed
    avifenc -q 60 -s 6 -- "$in" "$out" >/dev/null
  }
elif command -v ffmpeg >/dev/null 2>&1; then
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: ffprobe not found (usually bundled with ffmpeg). Install ffmpeg and retry." >&2
    exit 1
  fi

  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libsvtav1'; then
    ENC_ARGS=( -c:v libsvtav1 -crf 30 -preset 6 )
  elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'libaom-av1'; then
    ENC_ARGS=( -c:v libaom-av1 -still-picture 1 -crf 30 -b:v 0 )
  else
    echo "Error: no AV1 encoder found (need avifenc, or ffmpeg with libsvtav1/libaom-av1)." >&2
    exit 1
  fi

  encode() {
    local in="$1" out="$2"
    local pix_fmt
    pix_fmt="$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$in" || true)"

    if [[ "$pix_fmt" == *a* ]]; then
      echo "Warning: skipping alpha image (ffmpeg fallback cannot encode AVIF alpha): $in" >&2
      return 0
    fi

    ffmpeg -nostdin -hide_banner -loglevel error -y \
      -i "$in" \
      -frames:v 1 \
      "${ENC_ARGS[@]}" \
      "$out"
  }
else
  echo "Error: neither avifenc nor ffmpeg found. Install with 'brew install libavif ffmpeg'." >&2
  exit 1
fi

# Recursively convert jpg/png/webp → avif next to the source file.
# - Overwrites existing .avif files with same name.
# - Handles paths with spaces via NUL-delimited find output.
find "$TARGET_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 \
  | while IFS= read -r -d '' in; do
      out="${in%.*}.avif"
      encode "$in" "$out"
      echo "Converted: $out"
    done
