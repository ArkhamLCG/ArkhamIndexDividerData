#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-public/images}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found. Install it (e.g. 'brew install ffmpeg') and retry." >&2
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe not found (usually bundled with ffmpeg). Install ffmpeg and retry." >&2
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: directory not found: $TARGET_DIR" >&2
  exit 1
fi

# Recursively convert jpg/png/webp → avif next to the source file.
# - Overwrites existing .avif files with same name.
# - Handles paths with spaces via NUL-delimited find output.
find "$TARGET_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 \
  | while IFS= read -r -d '' in; do
      out="${in%.*}.avif"
      pix_fmt="$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$in" || true)"

      if [[ "$pix_fmt" == *a* ]]; then
        # AVIF transparency requires a 2nd stream for alpha.
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -i "$in" \
          -filter_complex "[0:v]format=yuv444p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv[main];[0:v]alphaextract,format=gray,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv[alpha]" \
          -map "[main]" -map "[alpha]" \
          -pix_fmt:v:0 yuv444p -pix_fmt:v:1 gray \
          -frames:v 1 \
          -c:v libaom-av1 -still-picture 1 -crf 30 -b:v 0 \
          "$out"
      else
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -i "$in" \
          -frames:v 1 \
          -c:v libaom-av1 -still-picture 1 -crf 30 -b:v 0 \
          "$out"
      fi
    done
