#!/bin/sh
# Render the README media from the recorded footage into ../assets/:
# the short hero GIF, one GIF per feature clip, the full tour MP4 and the social preview.
# Clip cuts live in src/timeline.ts (CLIPS); record footage first with app/scripts/promo-footage.sh.
set -eu
cd "$(dirname "$0")"
out=out
assets=../assets
mkdir -p "$out"

gif() { # composition width destination
    npx remotion render src/index.ts "$1" "$out/$1.mp4" --crf=16 --log=error
    ffmpeg -y -loglevel error -i "$out/$1.mp4" \
        -vf "fps=12,scale=$2:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
        "$assets/$3"
}

gif Hero 1200 hero.gif
gif Switch 1000 feature-switch.gif
gif Backlog 1000 feature-backlog.gif
gif Terminal 1000 feature-terminal.gif

npx remotion render src/index.ts Promo "$out/promo.mp4" --crf=16 --log=error
ffmpeg -y -loglevel error -i "$out/promo.mp4" -c:v libx264 -crf 22 -preset slow -pix_fmt yuv420p \
    -movflags +faststart -an "$assets/promo.mp4"
npx remotion still src/index.ts Social "$assets/social-preview.png" --log=error

ls -l "$assets"/hero.gif "$assets"/feature-*.gif "$assets"/promo.mp4
