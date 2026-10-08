#!/bin/zsh
#
# make_gifs.sh — convert the .mp4 demos into GIFs that render inline on GitHub
#
# WHY GIFS: GitHub sanitizes <video> tags out of markdown entirely, so the
# <video src="raw.githubusercontent.com/..."> approach in the README could never
# work no matter the codec or file size. Markdown *images* do render, so the
# demos have to be an image format. GIF is the only animated one GitHub is
# guaranteed to play inline (animated WebP is inconsistent).
#
# WHY THESE SETTINGS:
#   Trim to the first 12s.
#     GIF has no inter-frame compression and 256 colours, so size scales with
#     duration and on-screen motion. A 40s 3D-scene clip is 18x more expensive
#     per second than a flat UI clip. Trimming makes every GIF uniform and
#     small; the full-length .mp4s stay linked in the README for anyone who
#     wants the whole thing.
#   bayer dither, NOT sierra2_4a/error-diffusion.
#     Error diffusion scatters per-frame noise that GIF's LZW cannot compress.
#     Measured on the same clip: sierra2_4a -> 16.5 MB, bayer -> 2.2 MB. A 7.5x
#     difference for a barely visible quality change. Most important setting here.
#   640px wide, held fixed across every clip.
#     Consistency matters more than per-clip optimality in a README. 640px keeps
#     Chinese UI labels legible. When a clip is still too big, this script gives
#     up frame rate and colour count first, never the width.
#   128 colours, not 256.
#     Gradients in the 3D scenes dither badly at 256; 128 cuts size ~20% with no
#     practical difference at this scale.
#
# GIF is a 256-colour format with no inter-frame compression, so expect gradient
# banding on the 3D clips (auto_newbie, elements_wash, treasure_dig). That is
# inherent to the format, not a bug in these settings.
#
# USAGE
#   ./make_gifs.sh                 # every .mp4 in this directory
#   ./make_gifs.sh a.mp4 b.mp4     # specific files
#   ./make_gifs.sh --force *.mp4   # redo existing .gif files
#
# TUNABLES (environment variables)
#   TRIM        seconds to keep from the start, 0 = full length (default 12)
#   WIDTH       output width, held constant across clips (default 640)
#   FPS         starting frame rate (default 15)
#   MAX_COLORS  starting palette size (default 128)
#   MAX_BYTES   per-file ceiling, triggers a smaller retry (default 9000000)
#   BAYER_SCALE dither pattern size (default 3; higher = finer, slightly larger)

set -euo pipefail

TRIM=${TRIM:-12}
WIDTH=${WIDTH:-640}
FPS=${FPS:-15}
MAX_COLORS=${MAX_COLORS:-128}
MAX_BYTES=${MAX_BYTES:-9000000}
BAYER_SCALE=${BAYER_SCALE:-3}

FORCE=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) print -u2 "unknown flag: $arg"; exit 2 ;;
    *) ARGS+=("$arg") ;;
  esac
done

FILES=("${ARGS[@]}")
if (( ${#FILES} == 0 )); then
  FILES=( *.mp4(N) )
  (( ${#FILES} == 0 )) && { print -u2 "no .mp4 files here"; exit 1; }
fi

for bin in ffmpeg ffprobe; do
  command -v "$bin" >/dev/null || { print -u2 "missing dependency: $bin"; exit 1; }
done

# (fps, colours) tried in order until the result fits MAX_BYTES.
# Width is deliberately NOT in this list -- see the note above.
TIERS=("$FPS $MAX_COLORS" "12 128" "10 128" "10 96" "8 64")

# Leading filter chain shared by the palette pass and the apply pass.
pre() {
  local f=$1
  local chain=""
  (( TRIM > 0 )) && chain="trim=0:${TRIM},"
  chain+="setpts=PTS-STARTPTS,fps=$f,scale=${WIDTH}:-2:flags=lanczos"
  print -r -- "$chain"
}

RC=0
for src in "${FILES[@]}"; do
  [[ -f "$src" ]] || { print -u2 "skip (not a file): $src"; RC=1; continue; }
  out="${src%.*}.gif"

  if [[ -f "$out" && $FORCE -eq 0 ]]; then
    print "skip (exists): $out   [--force to redo]"
    continue
  fi

  pal=$(mktemp -t gifpal).png
  ok=0

  for tier in "${TIERS[@]}"; do
    f=${tier%% *}
    c=${tier##* }
    chain=$(pre "$f")

    ffmpeg -y -v error -i "$src" \
      -vf "${chain},palettegen=max_colors=${c}:stats_mode=diff" "$pal"
    ffmpeg -y -v error -i "$src" -i "$pal" \
      -lavfi "${chain}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=${BAYER_SCALE}" \
      -loop 0 "$out"

    sz=$(stat -f%z "$out")
    dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
            -of csv=p=0 "$out")
    if (( sz <= MAX_BYTES )); then
      printf "%-24s %-9s %2dfps %3dcol %8d bytes  %5.2f MiB\n" \
        "$out" "$dim" $f $c $sz "$(echo "$sz/1048576"|bc -l)"
      ok=1
      break
    fi
    printf "   %dfps/%dcol -> %d bytes, over ceiling; retrying\n" $f $c $sz
  done

  (( ok == 0 )) && { print -u2 "   FAILED to fit $out under $MAX_BYTES bytes"; RC=1; }
  rm -f "$pal"
done

exit $RC
