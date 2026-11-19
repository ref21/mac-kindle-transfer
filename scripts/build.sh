#!/bin/bash
# Builds libmtp (if needed), the Swift app, and assembles dist/Kindle Drive.app.
# Usage: build.sh [--install] [--deps-only] [--rebuild-deps] [-h|--help]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_VERSION="1.2"
APP_BUILD="3"
BUNDLE_ID="io.github.ref21.KindleDrive"
MIN_MACOS="14.0"

usage() { echo "Usage: $0 [--install] [--deps-only] [--rebuild-deps] [-h|--help]" >&2; }
INSTALL=0
DEPS_ONLY=0
REBUILD_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    --rebuild-deps) REBUILD_DEPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
INSTALL_DIR="/Applications"
if [ "$INSTALL" = 1 ] && pgrep -x KindleDrive >/dev/null; then
  echo "Kindle Drive is running. Quit it before installing." >&2
  exit 1
fi

# --- Preflight ---------------------------------------------------------------
case "$ROOT" in
  *[[:space:]]*)
    echo "Kindle Drive cannot be built from a folder whose path contains spaces (libmtp's build does not support it). Move the checkout, e.g. to ~/src/Kindle_Driver." >&2
    exit 1 ;;
esac
if ! command -v swift >/dev/null; then
  echo "swift not found. Install Xcode or the Command Line Tools (xcode-select --install)." >&2
  exit 1
fi
if ! command -v brew >/dev/null; then
  echo "Homebrew not found. Install it from https://brew.sh and then run: brew install libusb" >&2
  exit 1
fi
USB_PREFIX="$(brew --prefix libusb)"
if [ ! -f "$USB_PREFIX/include/libusb-1.0/libusb.h" ] || [ ! -f "$USB_PREFIX/lib/libusb-1.0.0.dylib" ]; then
  echo "libusb is not installed. Run: brew install libusb" >&2
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"

# --- libmtp ------------------------------------------------------------------
if [ "$REBUILD_DEPS" = 1 ]; then
  rm -rf Vendor/installed
  # Removes only git-ignored build products inside the vendored libmtp tree.
  git clean -fdXq Vendor/libmtp-1.1.22
fi
if [ ! -f Vendor/installed/lib/libmtp.9.dylib ]; then
  cd Vendor/libmtp-1.1.22
  ./configure --prefix="$ROOT/Vendor/installed" --disable-mtpz --disable-shared --enable-static --disable-doxygen LIBUSB_CFLAGS="-I$USB_PREFIX/include/libusb-1.0" LIBUSB_LIBS="-L$USB_PREFIX/lib -lusb-1.0"
  make -j"$(sysctl -n hw.ncpu)"
  make install
  cd "$ROOT"
  clang -dynamiclib Vendor/libmtp-1.1.22/src/libmtp_la-*.o -L"$USB_PREFIX/lib" -lusb-1.0 -liconv -install_name @rpath/libmtp.9.dylib -o Vendor/installed/lib/libmtp.9.dylib
  ln -sf libmtp.9.dylib Vendor/installed/lib/libmtp.dylib
fi
cp Vendor/installed/include/libmtp.h Sources/CMTP/include/libmtp.h
if [ "$DEPS_ONLY" = 1 ]; then
  exit 0
fi

# --- Swift build and bundle --------------------------------------------------
swift build -c release -debug-info-format none --disable-sandbox --cache-path .cache
BIN_DIR="$(swift build -c release --show-bin-path --disable-sandbox --cache-path .cache)"
APP="$ROOT/dist/Kindle Drive.app"
EXE="$APP/Contents/MacOS/KindleDrive"
FW="$APP/Contents/Frameworks"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$FW" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/KindleDrive" "$EXE"
cp Vendor/installed/lib/libmtp.9.dylib "$FW/"
cp "$USB_PREFIX/lib/libusb-1.0.0.dylib" "$FW/"
chmod u+w "$FW/"*.dylib
install_name_tool -change "$USB_PREFIX/lib/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$FW/libmtp.9.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$FW/libusb-1.0.0.dylib"

# Strip build-machine rpaths (e.g. the toolchain and Vendor/installed/lib) from the executable.
list_rpaths() {
  otool -l "$1" | awk '/cmd LC_RPATH/{f=1;next} f&&/^ *path /{sub(/^ *path /,""); sub(/ \(offset [0-9]+\)$/,""); print; f=0}'
}
while IFS= read -r rp; do
  case "$rp" in
    @*|/usr/lib/swift) ;;
    /*) install_name_tool -delete_rpath "$rp" "$EXE" ;;
  esac
done < <(list_rpaths "$EXE")
while IFS= read -r rp; do
  case "$rp" in
    @*|/usr/lib/swift) ;;
    *) echo "Error: executable still has a build-machine rpath: $rp" >&2; exit 1 ;;
  esac
done < <(list_rpaths "$EXE")
if otool -L "$EXE" | grep -q '@rpath/libswift'; then
  echo "Error: executable links a Swift back-deployment library (@rpath/libswift...) that needs the toolchain rpath; the bundle would crash on older macOS." >&2
  exit 1
fi

# Dependency checks: no direct libusb in the executable; non-system deps must be @rpath and bundled.
if otool -L "$EXE" | grep -q libusb; then
  echo "Error: the executable references libusb directly; only libmtp should." >&2
  exit 1
fi
for f in "$EXE" "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib"; do
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      @rpath/*)
        [ "$dep" = "@rpath/$(basename "$f")" ] && continue
        [ -f "$FW/${dep#@rpath/}" ] || { echo "Error: $(basename "$f") needs $dep, which is not in Contents/Frameworks." >&2; exit 1; } ;;
      *) echo "Error: $(basename "$f") has a non-portable dependency: $dep" >&2; exit 1 ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done

cp Vendor/libmtp-1.1.22/COPYING "$APP/Contents/Resources/Licenses/libmtp-LGPL.txt"
cp "$USB_PREFIX/COPYING" "$APP/Contents/Resources/Licenses/libusb-LGPL.txt"
cp THIRD_PARTY.md "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Exact bundled library versions.
LIBMTP_VERSION="$(basename Vendor/libmtp-1.1.22 | sed 's/^libmtp-//')"
LIBUSB_VERSION="$(brew list --versions libusb | awk '{print $2}')"
cat > "$APP/Contents/Resources/Licenses/VERSIONS.txt" <<VERSIONS
libmtp $LIBMTP_VERSION  https://github.com/libmtp/libmtp/tree/v$LIBMTP_VERSION
libusb $LIBUSB_VERSION  https://github.com/libusb/libusb
VERSIONS

# LSMinimumSystemVersion = highest minos of the bundled binaries, never below MIN_MACOS.
ver_num() { local IFS=.; set -- $1; echo $(( ${1:-0} * 10000 + ${2:-0} * 100 + ${3:-0} )); }
minos_of() { otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}'; }
LSMIN="$MIN_MACOS"
for f in "$EXE" "$FW/libmtp.9.dylib" "$FW/libusb-1.0.0.dylib"; do
  m="$(minos_of "$f")"
  if [ -n "$m" ] && [ "$(ver_num "$m")" -gt "$(ver_num "$LSMIN")" ]; then
    LSMIN="$m"
    echo "Note: minimum macOS raised to $LSMIN by $(basename "$f")"
  fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleExecutable</key><string>KindleDrive</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Kindle Drive</string>
<key>CFBundleDisplayName</key><string>Kindle Drive</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>$LSMIN</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSHumanReadableCopyright</key><string>Kindle Drive. Includes libmtp and libusb under LGPL.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null || { echo "Error: generated Info.plist is invalid." >&2; exit 1; }

# Sign inside-out, then verify.
codesign --force --sign - "$FW/libusb-1.0.0.dylib"
codesign --force --sign - "$FW/libmtp.9.dylib"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" || { echo "Error: code signature verification failed." >&2; exit 1; }
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
