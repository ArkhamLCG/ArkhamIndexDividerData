#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--clean-bak" ]]; then
  TARGET_DIR="${2:-public/images}"
  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: directory not found: $TARGET_DIR" >&2
    exit 1
  fi

  echo "Deleting .bak files in: $TARGET_DIR"
  find "$TARGET_DIR" -type f -name '*.bak' -print0 | xargs -0 rm -f
  exit 0
fi

TARGET_DIR="${1:-public/images}"
SIZE_LIMIT_BYTES="${SIZE_LIMIT_BYTES:-409600}" # 400 KB
MAIN_PIX_FMT="${MAIN_PIX_FMT:-yuv420p}"        # set to yuv444p if you see green tint
KEEP_BAK="${KEEP_BAK:-0}"                      # set to 1 to keep .bak for rollback

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

stat_size() {
  # macOS/BSD stat
  stat -f%z "$1"
}

probe_stream_tag() {
  local f="$1"
  local key="$2"
  ffprobe -v error -select_streams v:0 -show_entries "stream=${key}" -of default=nw=1:nk=1 "$f" 2>/dev/null || true
}

normalize_colorspace_matrix() {
  # ffprobe may return values like "gbr" (RGB) which are not valid for -colorspace/out_color_matrix.
  # Keep only known YUV matrix enums; fall back to bt709.
  local v="${1:-}"
  case "$v" in
    bt709|bt470bg|smpte170m|smpte240m|bt2020nc|bt2020c)
      echo "$v"
      ;;
    *)
      echo "bt709"
      ;;
  esac
}

normalize_primaries() {
  local v="${1:-}"
  case "$v" in
    bt709|bt470m|bt470bg|smpte170m|smpte240m|film|bt2020|smpte428|smpte431|smpte432|jedec-p22)
      echo "$v"
      ;;
    *)
      echo "bt709"
      ;;
  esac
}

normalize_trc() {
  local v="${1:-}"
  case "$v" in
    bt709|gamma22|gamma28|smpte170m|smpte240m|linear|log|log_sqrt|iec61966-2-4|bt1361e|iec61966-2-1|bt2020-10|bt2020-12|smpte2084|smpte428|arib-std-b67)
      echo "$v"
      ;;
    *)
      echo "bt709"
      ;;
  esac
}

normalize_range() {
  local v="${1:-}"
  case "$v" in
    tv|pc) echo "$v" ;;
    *) echo "tv" ;;
  esac
}

color_meta_score() {
  # Prefer files with explicit primaries/transfer/colorspace (avoids green-tint issues in some viewers).
  local f="$1"
  local prim trc spc
  prim="$(probe_stream_tag "$f" color_primaries)"
  trc="$(probe_stream_tag "$f" color_transfer)"
  spc="$(probe_stream_tag "$f" color_space)"

  local score=0
  [[ -n "$spc" && "$spc" != "unknown" && "$spc" != "unspecified" && "$spc" != "reserved" ]] && ((score+=1))
  [[ -n "$prim" && "$prim" != "unknown" && "$prim" != "unspecified" && "$prim" != "reserved" ]] && ((score+=1))
  [[ -n "$trc" && "$trc" != "unknown" && "$trc" != "unspecified" && "$trc" != "reserved" ]] && ((score+=1))
  echo "$score"
}

has_alpha() {
  local f="$1"
  local pix_fmt
  pix_fmt="$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$f" || true)"
  [[ "$pix_fmt" == *a* ]]
}

encode_variant() {
  local in="$1"
  local out="$2"
  local codec="$3"
  local crf="$4"
  local preset="$5"
  local alpha="$6" # "1" or "0"
  local color_space="${7:-bt709}"
  local color_primaries="${8:-bt709}"
  local color_trc="${9:-bt709}"
  local color_range="${10:-tv}" # tv=limited, pc=full
  local main_pix_fmt="${11:-yuv420p}"
  local rgb_identity="${12:-0}" # "1" means original was tagged as gbr (identity)

  local -a enc_args
  case "$codec" in
    svt)
      # SVT-AV1 tends to give good compression at similar quality.
      enc_args=( -c:v libsvtav1 -crf "$crf" -preset "$preset" )
      ;;
    aom)
      # AOM is slower but widely available; cpu-used trades speed for compression.
      enc_args=( -c:v libaom-av1 -still-picture 1 -crf "$crf" -b:v 0 -cpu-used "$preset" )
      ;;
    *)
      echo "Internal error: unknown codec '$codec'" >&2
      return 2
      ;;
  esac

  local -a ff_args
  ff_args=( ffmpeg -nostdin -hide_banner -loglevel error -y -i "$in" )

  if [[ "$alpha" == "1" ]]; then
    local filter
    if [[ "$rgb_identity" == "1" ]]; then
      # Don't force matrix conversion for identity-tagged sources.
      filter="[0:v]format=${main_pix_fmt}[main];[0:v]alphaextract,format=gray[alpha]"
    else
      filter="[0:v]scale=in_color_matrix=auto:out_color_matrix=${color_space}:in_range=auto:out_range=${color_range},format=${main_pix_fmt}[main];[0:v]alphaextract,format=gray[alpha]"
    fi

    ff_args+=( -filter_complex "$filter" -map "[main]" -map "[alpha]" -pix_fmt:v:0 "$main_pix_fmt" -pix_fmt:v:1 gray )
  else
    local vf
    if [[ "$rgb_identity" == "1" ]]; then
      vf="format=${main_pix_fmt}"
    else
      vf="scale=in_color_matrix=auto:out_color_matrix=${color_space}:in_range=auto:out_range=${color_range},format=${main_pix_fmt}"
    fi

    ff_args+=( -vf "$vf" )
  fi

  if [[ "$rgb_identity" != "1" ]]; then
    ff_args+=( -colorspace "$color_space" -color_primaries "$color_primaries" -color_trc "$color_trc" -color_range "$color_range" )
  fi

  ff_args+=( -frames:v 1 )
  ff_args+=( "${enc_args[@]}" )
  ff_args+=( "$out" )

  "${ff_args[@]}"
}

tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t 'avif-opt')"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

echo "Optimizing .avif files larger than ${SIZE_LIMIT_BYTES} bytes in: $TARGET_DIR"

find "$TARGET_DIR" -type f -iname '*.avif' -print0 \
  | while IFS= read -r -d '' file; do
      orig_size="$(stat_size "$file")"
      if (( orig_size <= SIZE_LIMIT_BYTES )); then
        continue
      fi

      alpha=0
      if has_alpha "$file"; then
        alpha=1
      fi

      # Preserve tags when available; fall back to sane defaults.
      raw_color_space="$(probe_stream_tag "$file" color_space)"
      color_space="$raw_color_space"
      color_primaries="$(probe_stream_tag "$file" color_primaries)"
      color_trc="$(probe_stream_tag "$file" color_transfer)"
      color_range="$(probe_stream_tag "$file" color_range)"

      rgb_identity=0
      if [[ "$raw_color_space" == "gbr" ]]; then
        rgb_identity=1
      fi

      color_space="$(normalize_colorspace_matrix "$color_space")"
      color_primaries="$(normalize_primaries "$color_primaries")"
      color_trc="$(normalize_trc "$color_trc")"
      color_range="$(normalize_range "$color_range")"

      base="$(basename "$file")"
      best_path="$file"
      best_size="$orig_size"
      best_meta_score="$(color_meta_score "$file")"

      # Try a small set of "likely wins" first; if still big, try more aggressive CRF.
      # preset meanings:
      # - svt: higher = faster, lower = better compression (varies by build)
      # - aom: cpu-used higher = faster, lower = better compression
      if [[ "$rgb_identity" == "1" ]]; then
        # SVT often fails on identity-matrix sources (gbr) and tends to negotiate 4:2:0.
        variants=(
          "aom 30 6"
          "aom 32 6"
        )
      else
        variants=(
          "svt 30 6"
          "aom 30 6"
          "svt 32 6"
          "aom 32 6"
        )
      fi

      for v in "${variants[@]}"; do
        read -r codec crf preset <<<"$v"
        candidate="$tmpdir/${base%.avif}.${codec}.crf${crf}.avif"

        # Identity/RGB-tagged sources are prone to green tint when subsampled; default to 4:4:4 for them.
        local_pix_fmt="$MAIN_PIX_FMT"
        if [[ "$rgb_identity" == "1" && "$MAIN_PIX_FMT" == "yuv420p" ]]; then
          local_pix_fmt="yuv444p"
        fi

        if ! encode_variant "$file" "$candidate" "$codec" "$crf" "$preset" "$alpha" "$color_space" "$color_primaries" "$color_trc" "$color_range" "$local_pix_fmt" "$rgb_identity"; then
          continue
        fi

        cand_size="$(stat_size "$candidate" || echo 0)"
        cand_meta_score="$(color_meta_score "$candidate")"

        # Prefer smaller. If within 2%, prefer better color metadata (helps avoid green tint).
        within_2pct=0
        if (( cand_size > 0 && best_size > 0 )) && (( cand_size * 100 <= best_size * 102 )); then
          within_2pct=1
        fi

        if (( cand_size > 0 )) && (
          (( cand_size < best_size )) || (( within_2pct == 1 && cand_meta_score > best_meta_score ))
        ); then
          best_size="$cand_size"
          best_path="$candidate"
          best_meta_score="$cand_meta_score"
        fi
      done

      # If still above the threshold, try more aggressive options.
      if (( best_size > SIZE_LIMIT_BYTES )); then
        if [[ "$rgb_identity" == "1" ]]; then
          aggressive_variants=(
            "aom 34 4"
            "aom 36 4"
          )
        else
          aggressive_variants=(
            "svt 34 6"
            "aom 34 4"
            "svt 36 6"
            "aom 36 4"
          )
        fi

        for v in "${aggressive_variants[@]}"; do
          read -r codec crf preset <<<"$v"
          candidate="$tmpdir/${base%.avif}.${codec}.crf${crf}.avif"

          local_pix_fmt="$MAIN_PIX_FMT"
          if [[ "$rgb_identity" == "1" && "$MAIN_PIX_FMT" == "yuv420p" ]]; then
            local_pix_fmt="yuv444p"
          fi

          if ! encode_variant "$file" "$candidate" "$codec" "$crf" "$preset" "$alpha" "$color_space" "$color_primaries" "$color_trc" "$color_range" "$local_pix_fmt" "$rgb_identity"; then
            continue
          fi

          cand_size="$(stat_size "$candidate" || echo 0)"
          cand_meta_score="$(color_meta_score "$candidate")"
          within_2pct=0
          if (( cand_size > 0 && best_size > 0 )) && (( cand_size * 100 <= best_size * 102 )); then
            within_2pct=1
          fi

          if (( cand_size > 0 )) && (
            (( cand_size < best_size )) || (( within_2pct == 1 && cand_meta_score > best_meta_score ))
          ); then
            best_size="$cand_size"
            best_path="$candidate"
            best_meta_score="$cand_meta_score"
          fi
        done
      fi

      if [[ "$best_path" != "$file" ]]; then
        cp -f "$file" "$file.bak"
        cp -f "$best_path" "$file"
        if [[ "${KEEP_BAK}" == "0" ]]; then
          rm -f "$file.bak"
        fi
        echo "Optimized: $file (${orig_size} -> ${best_size} bytes)"
      else
        echo "No improvement: $file (${orig_size} bytes)"
      fi
    done
