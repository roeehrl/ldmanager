#!/bin/bash
# The ≈15 s hero clip from four real UI states (demo/shots.sh + the fix sequence in
# demo/README.md), with caption pills: demo/out/clip/hero.mp4 and hero.gif.
set -euo pipefail
cd "$(dirname "$0")/.."
S=demo/out/shots; O=demo/out/clip; mkdir -p "$O"
frames=("$S/hero-dark.png" "$S/doctor-dark.png" "$S/fix-1-edit.png" "$S/fix-2-done.png")
caps=("A job failed. See why at every layer." "The Doctor names the cause and the fix." \
      "Diff before every save." "Fixed. Every edit keeps a backup.")
D=3.6; F=0.5   # seconds per state, crossfade
in=(); fc=""
for i in 0 1 2 3; do
  swift demo/caption.swift "${caps[$i]}" "$O/cap$i.png" 1600
  in+=(-loop 1 -t $D -i "${frames[$i]}" -i "$O/cap$i.png")
  y='H-h-36'; [ $i = 2 ] && y='h+150'   # the diff is at the bottom of state 2
  fc+="[$((2*i))]scale=1600:1000:flags=lanczos,format=rgba[f$i];[f$i][$((2*i+1))]overlay=(W-w)/2:$y,format=yuv420p,fps=30[v$i];"
done
fc+="[v0][v1]xfade=fade:duration=$F:offset=$(echo "$D-$F" | bc)[x1];"
fc+="[x1][v2]xfade=fade:duration=$F:offset=$(echo "2*$D-2*$F" | bc)[x2];"
fc+="[x2][v3]xfade=fade:duration=$F:offset=$(echo "3*$D-3*$F" | bc)[out]"
ffmpeg -loglevel error -y "${in[@]}" -filter_complex "$fc" -map "[out]" -c:v libx264 -preset slow -crf 22 \
  -pix_fmt yuv420p -movflags +faststart "$O/hero.mp4"
ffmpeg -loglevel error -y -i "$O/hero.mp4" -vf "fps=12,scale=880:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" "$O/hero.gif"
ls -la "$O/hero.mp4" "$O/hero.gif"
