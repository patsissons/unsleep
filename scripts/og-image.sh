#!/usr/bin/env bash
# Render site/og.png (the 1200×630 Open Graph image for unsleep.lgtm.page) with headless Chrome,
# from the logo in site/index.html and the menu screenshots in site/screenshots. Re-run it after
# changing either. Set CHROME to override the browser path.
set -euo pipefail

cd "$(dirname "$0")/.."

chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [[ ! -x "$chrome" ]]; then
  echo "og-image: Chrome not found at $chrome (set CHROME)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp/og.html" "$PWD/site" <<'PY'
import re, sys

out, site = sys.argv[1], sys.argv[2]
page = open(f"{site}/index.html", encoding="utf-8").read()
# Reuse the site's logo so the two never drift apart.
defs = re.search(r'<svg width="0" height="0"[^>]*>.*?</svg>', page, re.S).group(0)

html = """<!doctype html>
<html><head><meta charset="utf-8"><style>
  * { box-sizing: border-box; }
  html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; }
  body {
    position: relative;
    background:
      radial-gradient(760px 460px at 88% 18%, rgba(255, 179, 71, 0.20), transparent 70%),
      radial-gradient(700px 420px at 0% 100%, rgba(72, 88, 190, 0.30), transparent 70%),
      linear-gradient(180deg, #161b45, #0e1130);
    color: #eceaf4;
    font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .text { position: absolute; left: 72px; top: 64px; width: 560px; }
  .brand { display: flex; align-items: center; gap: 16px; font-size: 34px; font-weight: 700; }
  .brand svg { width: 56px; height: 56px; }
  h1 { margin: 64px 0 22px; font-size: 64px; line-height: 1.06; letter-spacing: -0.025em; }
  h1 em { font-style: normal; color: #ffb347; }
  p { margin: 0; font-size: 26px; line-height: 1.4; color: #a9abc6; }
  .url { position: absolute; left: 72px; bottom: 56px; font-size: 22px; font-weight: 500; color: #ffc06a; }
  img { position: absolute; display: block; filter: drop-shadow(0 24px 40px rgba(0, 0, 0, 0.55)); }
  .on { left: 628px; top: 52px; width: 414px; }
  .for { left: 738px; top: 286px; width: 410px; }
</style></head><body>
  DEFS
  <div class="text">
    <div class="brand"><svg viewBox="0 0 64 64"><use href="#logo"/></svg>UnSleep</div>
    <h1>Keep your Mac awake, <em>even with the lid closed</em></h1>
    <p>A tiny menu bar app and CLI for macOS.</p>
  </div>
  <div class="url">unsleep.lgtm.page</div>
  <img class="for" src="file://SITE/screenshots/keep-awake-for.png" alt="">
  <img class="on" src="file://SITE/screenshots/menu-on.png" alt="">
</body></html>
""".replace("DEFS", defs).replace("SITE", site)
open(out, "w", encoding="utf-8").write(html)
PY

"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --allow-file-access-from-files --window-size=1200,630 \
  --screenshot="$PWD/site/og.png" "file://$tmp/og.html" >/dev/null 2>&1
echo "wrote site/og.png"
