#!/bin/zsh
# Bangun "Smoosh.app" dari swift/Smoosh.swift dan smoosh.py.
set -euo pipefail
cd "${0:A:h}"

APP="Smoosh.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  swift/Smoosh.swift -o "$APP/Contents/MacOS/Smoosh"

cp smoosh.py assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Smoosh</string>
<key>CFBundleDisplayName</key><string>Smoosh</string>
<key>CFBundleIdentifier</key><string>local.smoosh</string>
<key>CFBundleExecutable</key><string>Smoosh</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Berkas</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array>
<string>com.adobe.pdf</string><string>public.jpeg</string><string>public.png</string>
<string>public.mpeg-4</string><string>com.apple.quicktime-movie</string><string>public.folder</string>
</array>
</dict></array>
</dict></plist>
EOF

xattr -cr "$APP"
codesign --force --deep -s - "$APP"
echo "Selesai: $PWD/$APP"
