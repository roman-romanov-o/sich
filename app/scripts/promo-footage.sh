#!/bin/sh
# Record promo footage of the real app from synthetic data only.
#
# Same sandbox idea as readme-screenshots.sh (empty synthetic home, synthetic
# projects), with scripts/promo-agent.sh — a fake Claude Code session — as every
# card's SHELL. SICH_PROMO=1 swaps the smoke for PromoRecorder: a scripted story through the real UI captured as 2x frames plus a beat timeline.
# The Remotion project in promo/ turns that footage into the promo video and GIF.
#
# Needs: ffmpeg, an awake display (run under `caffeinate -d -u -i`).
# Output: promo/public/footage.mp4 and promo/public/beats.json
set -e
cd "$(dirname "$0")/.."
app_dir=$(pwd)
out="$app_dir/../promo/public"
sandbox="$app_dir/.artifacts/readme-promo"
home="$sandbox/home"
project="$home/payments-api"

rm -rf "$sandbox"
mkdir -p "$out"
# One directory per card: promo-agent.sh picks each card's transcript by name.
for dir in payments-api auth-service quota-aggregation desktop-app reports \
        ghostty-focus public-api docs; do
    mkdir -p "$home/$dir"
done
touch "$project/pyproject.toml"

swift build
CFFIXED_USER_HOME="$home" SICH_REPO_ROOT="$project" SHELL="$app_dir/scripts/promo-agent.sh" \
    SICH_E2E=1 SICH_PROMO=1 .build/debug/sich

frames="$project/app/.artifacts/promo"
ffmpeg -v error -y -f concat -safe 0 -i "$frames/frames.txt" \
    -vf "fps=30,format=yuv420p" -c:v libx264 -crf 14 -preset slow "$out/footage.mp4"
cp "$frames/beats.json" "$out/beats.json"
ls -lh "$out/footage.mp4"
cat "$out/beats.json"
