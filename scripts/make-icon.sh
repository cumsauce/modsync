#!/usr/bin/env bash
# Builds build/AppIcon.icns from scripts/make-icon.swift.
#
# Kept separate from make-app.sh so the iconset can be regenerated and eyeballed
# on its own. Requires only stock macOS tools: swift, sips, iconutil.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/build}"

mkdir -p "$out"

swift "$root/scripts/make-icon.swift" "$out/icon-1024.png"

iconset="$out/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"

# iconutil expects these exact names; 512@2x is the 1024 master.
for size in 16 32 128 256; do
  sips -z "$size" "$size" "$out/icon-1024.png" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$out/icon-1024.png" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 512 512 "$out/icon-1024.png" --out "$iconset/icon_512x512.png" >/dev/null
cp "$out/icon-1024.png" "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$out/AppIcon.icns"

echo "wrote $out/AppIcon.icns"
