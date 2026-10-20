#!/bin/bash
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$SRC/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

card_height() {
  local probe="$SRC/.$1.measure.html"
  sed 's#</body>#<script>document.body.setAttribute("data-h", Math.ceil(document.querySelector(".card").getBoundingClientRect().height))</script></body>#' "$SRC/$1.html" > "$probe"
  "$CHROME" --headless=new --disable-gpu --window-size=882,1600 --virtual-time-budget=6000 --dump-dom "file://$probe" 2>/dev/null | grep -o 'data-h="[0-9]*"' | grep -o '[0-9]*'
  rm -f "$probe"
}

for name in hero how beforeafter ledger parallel shortlist; do
  height=$(card_height "$name")
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --default-background-color=00000000 --window-size=882,$((height + 2)) --virtual-time-budget=6000 \
    --screenshot="$OUT/$name.png" "file://$SRC/$name.html" >/dev/null 2>&1
  echo "rendered assets/$name.png"
done
