#!/usr/bin/env bash
# Turntable frames (render_glasses.py) → the README's hero and still, keeping transparency.
# Cropped to the union of every frame's bounding box, so the hero has no empty margin.
set -euo pipefail
cd "$(dirname "$0")/.."
F=.build/turntable C=.build/crop
rm -rf "$C" && mkdir -p "$C"
ffmpeg -loglevel error -i "$F/f_%04d.png" -vf "crop=624:252:108:69" "$C/f_%04d.png"
img2webp -loop 0 -d 83 -lossy -q 82 -m 4 $(ls "$C"/f_*.png) -o assets/hero.webp
cwebp -quiet -q 88 -alpha_q 100 -resize 480 0 "$C/f_0001.png" -o assets/iris-glasses.webp
ls -la assets/hero.webp assets/iris-glasses.webp
