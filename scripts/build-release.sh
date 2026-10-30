#!/bin/bash
# Builds "Kikumap.app" for Apple silicon and Intel, signs it and puts it in a disk image in dist/
# for a GitHub release. (No Apple Developer ID: people open it once with "Open Anyway".)
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
OUT=dist
APP="$OUT/Kikumap.app"
# only what this script makes: anything else kept in dist/ (release notes, say) stays
rm -rf "$APP" "$OUT/Kikumap" "$OUT/raw.dmg" "$OUT/Kikumap.dmg" "$OUT"/bin-* "$OUT"/wx-* "$OUT/.modules" "$OUT/dmg-background"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  echo "Building $arch…"
  xcrun swiftc -O -parse-as-library -module-cache-path "$OUT/.modules" -target "$arch-apple-macos13.0" -o "$OUT/bin-$arch" Sources/*.swift \
    -framework Cocoa -framework Security -framework Carbon -framework WidgetKit -lsqlite3
done
lipo -create -output "$APP/Contents/MacOS/ClaudeConsole" "$OUT/bin-arm64" "$OUT/bin-x86_64"
# the desktop widget (macOS 14+): an extension inside the app, sandboxed to reading one file
WX="$APP/Contents/PlugIns/KikumapWidget.appex"
mkdir -p "$WX/Contents/MacOS"
# It starts in NSExtensionMain, as Xcode links extensions: started at its own main, it quits at once.
for arch in arm64 x86_64; do
  echo "Building the widget, $arch…"
  xcrun swiftc -O -parse-as-library -application-extension -module-cache-path "$OUT/.modules" -target "$arch-apple-macos14.0" \
    -module-name KikumapWidget -o "$OUT/wx-$arch" Widget/*.swift -framework SwiftUI -framework WidgetKit -framework Foundation \
    -Xlinker -e -Xlinker _NSExtensionMain
done
lipo -create -output "$WX/Contents/MacOS/KikumapWidget" "$OUT/wx-arm64" "$OUT/wx-x86_64"
rm -rf "$OUT"/bin-* "$OUT"/wx-* "$OUT/.modules"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/LICENSE-lucide.txt "$APP/Contents/Resources/"
cp Widget/Info.plist "$WX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VER" \
  -c "Set CFBundleVersion $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)" "$WX/Contents/Info.plist"
"$APP/Contents/MacOS/ClaudeConsole" --make-icns "$APP/Contents/Resources/AppIcon.icns"
# Signed with the same certificate every release, so macOS keeps people's permissions across updates
# (it recognises an app by its signature). The certificate is the self-signed one Install.command makes
# once; without it, an ad-hoc signature, and permissions reset with every update.
# The widget first, with its sandbox entitlements, then the app around it (not --deep: that would
# sign the widget again without them). The widget is signed ad hoc, as Xcode signs local builds: macOS
# won't list a widget whose certificate it doesn't trust (the self-signed one), and it needs no permissions.
sign() {
  codesign --force -s - --entitlements Widget/Widget.entitlements "$WX" && codesign --force -s "$1" "$APP"
}
IDENT=""
for c in "Claude Console Local Signing" "Kikumap Local Signing"; do            # the order Install.command uses
  if security find-identity -p codesigning | grep -q "\"$c\""; then IDENT="$c"; break; fi
done
if [ -n "$IDENT" ]; then
  sign "$IDENT" || { echo "Signing with \"$IDENT\" failed (keychain access denied?)"; exit 1; }
  echo "Signed with \"$IDENT\" (permissions survive updates)"
elif [ "${ALLOW_ADHOC:-0}" = 1 ]; then
  sign -
  echo "Signed ad hoc: everyone will have to grant permissions again after this update"
else
  echo "No local signing certificate: run Install.command once to make one (or ALLOW_ADHOC=1 to sign ad hoc)"; exit 1
fi

# The disk image: Kikumap and an Applications shortcut side by side over a background picture with an
# arrow, Kikumap's icon on the volume. (makehybrid builds it straight from the folder, without mounting
# anything; dmg-layout.py --fix then points the window at the picture.)
STAGE="$OUT/Kikumap"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Kikumap.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
mkdir -p "$STAGE/.background"
xcrun swiftc -module-cache-path "$OUT/.modules" -o "$OUT/dmg-background" scripts/dmg-background.swift
"$OUT/dmg-background" "$STAGE/.background/background.tiff"
rm -rf "$OUT/dmg-background" "$OUT/.modules"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$STAGE"
python3 scripts/dmg-layout.py "$STAGE"
hdiutil makehybrid -quiet -hfs -hfs-volume-name Kikumap -hfs-openfolder "$STAGE" -o "$OUT/raw.dmg" "$STAGE"
python3 scripts/dmg-layout.py --fix "$OUT/raw.dmg" "$STAGE"
hdiutil convert -quiet "$OUT/raw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT/Kikumap.dmg"
rm -rf "$STAGE" "$OUT/raw.dmg"
echo "Done: $OUT/Kikumap.dmg (version $VER)"
