#!/bin/bash
set -euo pipefail

# Renders scripts/icon.svg into every PNG in the app icon set, and rewrites that
# set's Contents.json to match.
#
# Usage: ./scripts/make-icon.sh [-c|--check]
#
#   -c, --check   Render to a temporary directory and diff against the committed
#                 PNGs instead of overwriting them. Exits non-zero if the icons
#                 on disk are not what icon.svg currently says they should be.
#
# One 1024 master is rendered from the vector and every smaller size is
# downsampled from it, rather than each size being rendered from the SVG at its
# own scale. Rendering small directly lets each size snap to its own pixel grid,
# and the marked line and the margin chip — the only two things worth seeing at
# 16pt — end up a different weight in every rendition.

CHECK=false
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check) CHECK=true ;;
        *) echo "Unknown option: $1"; echo "Usage: $0 [-c|--check]"; exit 1 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MASTER="$SCRIPT_DIR/icon.svg"
ICONSET="$PROJECT_DIR/Revis/Assets.xcassets/AppIcon.appiconset"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "error: needs Google Chrome to rasterise the SVG, and it is not at" >&2
    echo "       $CHROME" >&2
    echo "       Any SVG rasteriser will do; the PNGs are committed, so this is" >&2
    echo "       only needed when icon.svg changes." >&2
    exit 1
fi
if ! python3 -c "import PIL" 2>/dev/null; then
    echo "error: needs Python's Pillow for the downsampling (pip3 install Pillow)." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OUT="$ICONSET"
$CHECK && OUT="$WORK/out" && mkdir -p "$OUT"

# Chrome will not screenshot a file:// SVG directly with a transparent ground,
# so the master is wrapped in a page whose background is left unpainted.
printf '<html><head><style>html,body{margin:0;padding:0;background:transparent}</style></head><body>%s</body></html>' \
    "$(cat "$MASTER")" > "$WORK/render.html"

"$CHROME" --headless --disable-gpu --hide-scrollbars \
    --default-background-color=00000000 --force-device-scale-factor=1 \
    --screenshot="$WORK/master-1024.png" --window-size=1024,1024 \
    "$WORK/render.html" >/dev/null 2>&1

[ -s "$WORK/master-1024.png" ] || { echo "error: Chrome produced no master render." >&2; exit 1; }

python3 - "$WORK/master-1024.png" "$OUT" <<'PY'
import json, sys
from PIL import Image

master_path, out_dir = sys.argv[1], sys.argv[2]
master = Image.open(master_path).convert("RGBA")
if master.size != (1024, 1024):
    sys.exit(f"error: master rendered at {master.size}, expected (1024, 1024)")

images = []
for size in (16, 32, 128, 256, 512):
    for scale, suffix in (("1x", ""), ("2x", "@2x")):
        px = size * (2 if scale == "2x" else 1)
        name = f"icon_{size}x{size}{suffix}.png"
        img = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
        img.save(f"{out_dir}/{name}", "PNG", optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": scale, "size": f"{size}x{size}"})

doc = {"images": images, "info": {"author": "xcode", "version": 1}}
# Xcode writes this catalog with a space before the colon; matching it keeps the
# file from churning every time Xcode touches the asset catalog.
with open(f"{out_dir}/Contents.json", "w") as f:
    f.write(json.dumps(doc, indent=2).replace('": ', '" : ') + "\n")
PY

if $CHECK; then
    if diff -rq "$OUT" "$ICONSET" >/dev/null 2>&1; then
        echo "✓ app icon matches scripts/icon.svg"
    else
        echo "✗ app icon does NOT match scripts/icon.svg:" >&2
        diff -rq "$OUT" "$ICONSET" >&2 || true
        echo "  run ./scripts/make-icon.sh to regenerate." >&2
        exit 1
    fi
else
    echo "✓ wrote 10 PNGs and Contents.json to Revis/Assets.xcassets/AppIcon.appiconset"
fi
