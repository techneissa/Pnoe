#!/bin/zsh
# Regenerates Pnoe's app icon PNGs and the menu bar glyph from the SVGs in this folder.
# Needs Inkscape: brew install inkscape
set -euo pipefail
cd "${0:A:h}"
INKSCAPE=${INKSCAPE:-/opt/homebrew/bin/inkscape}
ASSETS=../../Pnoe/Assets.xcassets

for px in 16 32 64 128 256 512 1024; do
  "$INKSCAPE" pnoe-icon.svg --export-type=png --export-width=$px --export-height=$px \
    --export-filename="$ASSETS/AppIcon.appiconset/$px-mac.png" >/dev/null 2>&1
done

# Menu bar template glyph: 22x18 pt at 1x and 2x.
GLYPH=$ASSETS/MenuBarGlyph.imageset
mkdir -p "$GLYPH"
"$INKSCAPE" pnoe-menubar-glyph.svg --export-type=png --export-width=22 --export-height=18 \
  --export-filename="$GLYPH/MenuBarGlyph.png" >/dev/null 2>&1
"$INKSCAPE" pnoe-menubar-glyph.svg --export-type=png --export-width=44 --export-height=36 \
  --export-filename="$GLYPH/MenuBarGlyph@2x.png" >/dev/null 2>&1
echo "rendered"
