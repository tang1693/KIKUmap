#!/bin/bash
# Double-click: build Kikumap from source and install it to ~/Applications.
cd "$(dirname "$0")" || exit 1
DIR="$(pwd)"
mkdir -p "$DIR/logs"
exec > >(tee "$DIR/logs/install.log") 2>&1

echo "== Kikumap install  $(date) =="
sw_vers 2>/dev/null | tr '\n' ' '; echo

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. macOS will offer to install the Command Line Tools — click Install, then run this again."
  xcode-select --install 2>/dev/null
  echo "STATUS=NEED_CLT"; exit 1
fi

APP="$HOME/Applications/Kikumap.app"
OLD="$HOME/Applications/Claude中控台.app"       # its earlier names
OLD2="$HOME/Applications/Kiku.app"
TMP="$(mktemp -d)"
echo "Building…"
if ! xcrun swiftc -O -parse-as-library -o "$TMP/ClaudeConsole" Sources/*.swift \
     -framework Cocoa -framework Security -framework Carbon -framework WidgetKit -lsqlite3; then
  echo "STATUS=BUILD_FAILED"; exit 1
fi
# the desktop widget needs macOS 14; without it everything else still works. It starts in
# NSExtensionMain, as Xcode links extensions: started at its own main, it quits at once.
WIDGET=0
if xcrun swiftc -O -parse-as-library -application-extension -target "$(uname -m)-apple-macos14.0" -module-name KikumapWidget \
     -o "$TMP/KikumapWidget" Widget/*.swift -framework SwiftUI -framework WidgetKit -framework Foundation \
     -Xlinker -e -Xlinker _NSExtensionMain 2>/dev/null; then
  WIDGET=1
else
  echo "(desktop widget skipped: it needs macOS 14 or later)"
fi

pkill -x ClaudeConsole 2>/dev/null
sleep 0.5
mkdir -p "$HOME/Applications"
rm -rf "$APP" "$OLD" "$OLD2"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$TMP/ClaudeConsole" "$APP/Contents/MacOS/ClaudeConsole"
WX="$APP/Contents/PlugIns/KikumapWidget.appex"
if [ "$WIDGET" = 1 ]; then
  mkdir -p "$WX/Contents/MacOS"
  mv "$TMP/KikumapWidget" "$WX/Contents/MacOS/KikumapWidget"
  cp Widget/Info.plist "$WX/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)" \
    -c "Set CFBundleVersion $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)" "$WX/Contents/Info.plist"
fi
rm -rf "$TMP"
[ -d "/Applications/Kikumap.app" ] && echo "Note: there's also a Kikumap in /Applications (from the disk image). Delete one of them, so only one runs."
cp Resources/Info.plist "$APP/Contents/Info.plist"
# the icon is drawn in code (Sources/Logo.swift)
"$APP/Contents/MacOS/ClaudeConsole" --make-icns "$APP/Contents/Resources/AppIcon.icns" || echo "(icon skipped)"
# Sign with a certificate that stays the same across rebuilds, so macOS keeps the permissions you
# granted. Made once and kept in your login keychain; only this Mac uses it.
IDENT="Kikumap Local Signing"
# made under the app's earlier name: keep using it, so permissions carry over
security find-certificate -c "Claude Console Local Signing" >/dev/null 2>&1 && IDENT="Claude Console Local Signing"
if ! security find-certificate -c "$IDENT" >/dev/null 2>&1; then
  echo "Creating a local signing certificate in your login keychain (once), so macOS keeps"
  echo "Kikumap's permissions when you rebuild. It only signs Kikumap, on this Mac."
  C="$(mktemp -d)"
  cat > "$C/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENT
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CFG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$C/key.pem" -out "$C/cert.pem" -days 3650 -config "$C/cfg" >/dev/null 2>&1 &&
  /usr/bin/openssl pkcs12 -export -inkey "$C/key.pem" -in "$C/cert.pem" -out "$C/id.p12" -passout pass:cc -name "$IDENT" >/dev/null 2>&1 &&
  security import "$C/id.p12" -P cc -T /usr/bin/codesign >/dev/null 2>&1 && FIRST_CERT=1
  rm -rf "$C"
fi
if [ "${FIRST_CERT:-0}" = 1 ]; then
  echo "macOS may now ask whether codesign may use that certificate: choose Always Allow."
fi
# the widget first, with its sandbox entitlements, then the app around it (not --deep: that would
# sign the widget again without them)
sign() {
  # the widget ad hoc (macOS won't list one signed with an untrusted certificate; it needs no permissions)
  if [ -d "$WX" ]; then codesign --force -s - --entitlements Widget/Widget.entitlements "$WX" || return 1; fi
  codesign --force -s "$1" "$APP"
}
if sign "$IDENT" 2>/dev/null; then
  echo "Signed with the local certificate (permissions survive reinstalls)."
  SIGNED=stable
else
  sign - || echo "(signing skipped)"
  SIGNED=adhoc
fi

# data (map, read state, logs) lives in ~/Library/Application Support/ClaudeConsole
# (unless an earlier install pointed it somewhere else — that's kept)

PL="$HOME/Library/LaunchAgents/ninja.tang.claudeconsole.plist"
echo
if [ -f "$PL" ]; then
  ANS=y
  echo "Starts at login (your earlier choice, kept)."
else
  read -r -p "Start Kikumap automatically at login? (y = yes, Enter = no): " ANS
fi
if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ninja.tang.claudeconsole</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-a</string><string>$APP</string><string>--args</string><string>--background</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
[ -f "$PL" ] && echo "Will start at login."
else
rm -f "$PL"
echo "Not starting at login."
fi

open "$APP"
echo "STATUS=OK"
echo "Done. Menu bar: red number = unread (! = needs your approval), turning orange burst = running. ⌃⌥C opens the map."
if [ "$SIGNED" = "stable" ] && [ -z "$FIRST_CERT" ]; then
  echo "Permissions you granted before are kept."
else
  echo "If access shows as off: remove Kikumap in System Settings → Privacy & Security (−) and add it again."
  [ "$SIGNED" = "stable" ] && echo "This is the last time — from now on the signature stays the same."
fi
