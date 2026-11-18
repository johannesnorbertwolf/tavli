#!/bin/bash
# Renders every mock screen + the comparison sheet to design/dark-mode/renders/.
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DIR="$(pwd)"
mkdir -p renders
shot() { # url out w h
  "$CHROME" --headless --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=2 --virtual-time-budget=1500 \
    --window-size="$3,$4" --screenshot="$DIR/renders/$2" "$1" >/dev/null 2>&1
}
for t in light espresso night walnut felt c1 c2 c3 c4; do
  for s in game start; do
    shot "file://$DIR/mock.html#theme=$t&screen=$s" "$t-$s.png" 390 844
  done
done
shot "file://$DIR/sheet.html" "comparison.png" 2290 1610
shot "file://$DIR/c-sheet.html" "c-variants.png" 2060 1530
echo done
