#!/usr/bin/env bash
# Assembles build/… into a macOS .app bundle.
#
# A bare Mach-O launched from Finder is handed to Terminal, which is why the
# release used to open a shell window. A bundle with CFBundlePackageType APPL
# launches as a normal GUI app, and it is the only way to carry an icon.
#
# Usage: make-app.sh <binary> <version> [out-dir]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${1:?usage: make-app.sh <binary> <version> [out-dir]}"
version="${2:-0.0.0}"
out="${3:-$root/dist}"

if [ ! -x "$bin" ]; then
  echo "error: $bin is not an executable" >&2
  exit 1
fi

app="$out/modsync.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin" "$app/Contents/MacOS/modsync"
chmod 755 "$app/Contents/MacOS/modsync"

if [ ! -f "$root/build/AppIcon.icns" ]; then
  bash "$root/scripts/make-icon.sh" "$root/build" >/dev/null
fi
cp "$root/build/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>modsync</string>
	<key>CFBundleDisplayName</key>
	<string>modsync</string>
	<key>CFBundleIdentifier</key>
	<string>com.cumsauce.modsync</string>
	<key>CFBundleVersion</key>
	<string>${version}</string>
	<key>CFBundleShortVersionString</key>
	<string>${version}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>modsync</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSRequiresAquaSystemAppearance</key>
	<false/>
</dict>
</plist>
PLIST

# Determine the icon by path too, for tools that ignore CFBundleIconFile.
/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" >/dev/null

# Ad-hoc signature: an unsigned bundle on Apple Silicon is killed on launch.
# This is not notarisation, so Gatekeeper still quarantines a download.
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1 || \
  echo "warning: ad-hoc codesign unavailable; the bundle may not launch" >&2

echo "wrote $app"
