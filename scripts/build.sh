#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "Usage: $0 [--install]" >&2; exit 2 ;;
  esac
done
INSTALL_DIR="/Applications"
if [ "$INSTALL" = 1 ] && pgrep -x KindleDrive >/dev/null; then
  echo "Kindle Drive is running. Quit it before installing." >&2
  exit 1
fi
USB_PREFIX="$(brew --prefix libusb)"
export MACOSX_DEPLOYMENT_TARGET=15.0
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
if [ ! -f Vendor/installed/lib/libmtp.9.dylib ]; then
  cd Vendor/libmtp-1.1.22
  ./configure --prefix="$ROOT/Vendor/installed" --disable-mtpz --disable-shared --enable-static --disable-doxygen LIBUSB_CFLAGS="-I$USB_PREFIX/include/libusb-1.0" LIBUSB_LIBS="-L$USB_PREFIX/lib -lusb-1.0"
  make -j4
  make install
  cd "$ROOT"
  clang -dynamiclib Vendor/libmtp-1.1.22/src/libmtp_la-*.o -L"$USB_PREFIX/lib" -lusb-1.0 -liconv -install_name @rpath/libmtp.9.dylib -o Vendor/installed/lib/libmtp.9.dylib
  ln -sf libmtp.9.dylib Vendor/installed/lib/libmtp.dylib
fi
cp Vendor/installed/include/libmtp.h Sources/CMTP/include/libmtp.h
swift build -c release -debug-info-format none --disable-sandbox --cache-path .cache
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .cache)"
APP="$ROOT/dist/Kindle Drive.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/KindleDrive" "$APP/Contents/MacOS/KindleDrive"
cp Vendor/installed/lib/libmtp.9.dylib "$APP/Contents/Frameworks/"
cp "$USB_PREFIX/lib/libusb-1.0.0.dylib" "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/"*.dylib
install_name_tool -change "$USB_PREFIX/lib/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libmtp.9.dylib"
install_name_tool -change "$USB_PREFIX/lib/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$APP/Contents/MacOS/KindleDrive"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
cp Vendor/libmtp-1.1.22/COPYING "$APP/Contents/Resources/Licenses/libmtp-LGPL.txt"
cp "$USB_PREFIX/COPYING" "$APP/Contents/Resources/Licenses/libusb-LGPL.txt"
cp THIRD_PARTY.md "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KindleDrive</string>
<key>CFBundleIdentifier</key><string>local.kindledrive.app</string>
<key>CFBundleName</key><string>Kindle Drive</string>
<key>CFBundleDisplayName</key><string>Kindle Drive</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSHumanReadableCopyright</key><string>Kindle Drive. Includes libmtp and libusb under LGPL.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
codesign --force --sign - "$APP/Contents/Frameworks/libmtp.9.dylib"
codesign --force --sign - "$APP"
echo "Built: $APP"
if [ "$INSTALL" = 1 ]; then
  DEST="$INSTALL_DIR/Kindle Drive.app"
  STAGE="$INSTALL_DIR/.Kindle Drive.app.installing"
  rm -rf "$STAGE"
  ditto "$APP" "$STAGE"
  rm -rf "$DEST"
  mv "$STAGE" "$DEST"
  # Make Finder and the Dock pick up the new icon and bundle contents.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  touch "$DEST"
  echo "Installed: $DEST"
fi
