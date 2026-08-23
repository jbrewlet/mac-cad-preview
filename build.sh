#!/bin/bash
# Build Mac CAD Preview.app with its embedded Quick Look preview extension.
# No Xcode required — Command Line Tools only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
# Single source of truth for the version. The Info.plists are stamped from it
# below rather than edited by hand, so a release is a one line change here.
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$BUILD/Mac CAD Preview.app"
APPEX="$APP/Contents/PlugIns/MacCADPreviewQL.appex"
FRAMEWORKS="$APPEX/Contents/Frameworks"
OCC="$(brew --prefix opencascade)"
DEPLOY="12.0"

# Homebrew's OpenCASCADE is arm64-only, so this build is arm64-only too.
# Universal (Intel) support needs OCCT compiled from source for both arches.
ARCH="arm64"

OCC_LIBS=(TKernel TKMath TKG2d TKG3d TKGeomBase TKGeomAlgo TKBRep TKTopAlgo TKXCAF TKLCAF TKCDF TKCAF TKVCAF
          TKMesh TKShHealing TKXSBase TKDESTEP TKDEIGES TKDESTL)

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# CFBundleShortVersionString is what the user sees; CFBundleVersion is what
# macOS compares to decide an app has been updated. Both track VERSION.
stamp_version() {
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $VERSION" \
        "$1" >/dev/null
}

say "Building Mac CAD Preview $VERSION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APPEX/Contents/MacOS" "$FRAMEWORKS"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------ geometry core
say "Compiling geometry core (OpenCASCADE)"
clang++ -std=c++17 -O2 -fPIC \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -I"$OCC/include/opencascade" -I"$ROOT/src/core" \
    -c "$ROOT/src/core/cadmesh.cpp" -o "$TMP/cadmesh.o"
clang++ -std=c++17 -O2 -fPIC \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -I"$OCC/include/opencascade" -I"$ROOT/src/core" \
    -c "$ROOT/src/core/read_3mf.cpp" -o "$TMP/read_3mf.o"

say "Building probe CLI"
clang++ -std=c++17 -O2 \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -I"$OCC/include/opencascade" -I"$ROOT/src/core" \
    -DCADPROBE_VERSION="\"$VERSION\"" \
    "$TMP/cadmesh.o" "$TMP/read_3mf.o" "$ROOT/src/core/probe_main.cpp" \
    -L"$OCC/lib" "${OCC_LIBS[@]/#/-l}" -lz -Wl,-rpath,"$OCC/lib" \
    -o "$BUILD/cadprobe"

# ---------------------------------------------------------------- host app
say "Compiling host app"
swiftc -O \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -module-name MacCADPreview \
    -framework Cocoa \
    -o "$APP/Contents/MacOS/MacCADPreview" \
    "$ROOT/src/app/main.swift" \
    "$ROOT/src/app/SettingsWindow.swift" \
    "$ROOT/src/shared/PreviewPreferences.swift"
cp "$ROOT/src/app/Info.plist" "$APP/Contents/Info.plist"
stamp_version "$APP/Contents/Info.plist"

# ----------------------------------------------------------- xpc helper
# Embedded in the .appex (not the host app) so the sandboxed extension
# can reach it. Application-type XPC in the host .app is app-only.
XPC="$APPEX/Contents/XPCServices/MacCADPreviewHelper.xpc"
mkdir -p "$XPC/Contents/MacOS"
say "Compiling XPC helper"
swiftc -O \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -module-name MacCADPreviewHelper \
    -framework Cocoa \
    -o "$XPC/Contents/MacOS/MacCADPreviewHelper" \
    "$ROOT/src/xpc/main.swift" \
    "$ROOT/src/qlext/FusionOpener.swift" \
    "$ROOT/src/shared/FusionXPC.swift" \
    "$ROOT/src/shared/HostApp.swift"
cp "$ROOT/src/xpc/Info.plist" "$XPC/Contents/Info.plist"

# ----------------------------------------------------------- ql extension
# An .appex has no main(); its entry point is NSExtensionMain from Foundation.
say "Compiling archive listing"
clang -std=c11 -O2 -fPIC \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -I"$ROOT/src/qlext" \
    -c "$ROOT/src/qlext/archivelist.c" -o "$TMP/archivelist.o"

say "Compiling Quick Look extension"
swiftc -O \
    -target "${ARCH}-apple-macos${DEPLOY}" \
    -module-name MacCADPreviewQL \
    -parse-as-library \
    -application-extension \
    -import-objc-header "$ROOT/src/qlext/QLBridging.h" \
    -I"$ROOT/src/core" -I"$ROOT/src/qlext" \
    -framework Cocoa -framework Quartz -framework SceneKit \
    "$TMP/cadmesh.o" "$TMP/read_3mf.o" "$TMP/archivelist.o" \
    -L"$OCC/lib" "${OCC_LIBS[@]/#/-l}" -lc++ -lz -larchive \
    -Xlinker -rpath -Xlinker "@loader_path/../Frameworks" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX/Contents/MacOS/MacCADPreviewQL" \
    "$ROOT/src/qlext/PreviewViewController.swift" \
    "$ROOT/src/qlext/GCodeHighlighter.swift" \
    "$ROOT/src/qlext/MarkdownPreview.swift" \
    "$ROOT/src/qlext/ArchivePreview.swift" \
    "$ROOT/src/shared/PreviewPreferences.swift" \
    "$ROOT/src/qlext/MeshData.swift" \
    "$ROOT/src/qlext/FusionOpener.swift" \
    "$ROOT/src/shared/FusionXPC.swift" \
    "$ROOT/src/shared/HostApp.swift" \
    "$ROOT/src/qlext/FusionOpenButton.swift"
cp "$ROOT/src/qlext/Info.plist" "$APPEX/Contents/Info.plist"
stamp_version "$APPEX/Contents/Info.plist"

# ------------------------------------------------------------- dylib bundling
# A sandboxed extension cannot be relied on to load libraries out of
# /opt/homebrew, and friends won't have Homebrew at all — so copy every
# non-system dependency inside the bundle and repoint the load commands.
say "Bundling OpenCASCADE libraries"
EXE="$APPEX/Contents/MacOS/MacCADPreviewQL"

# OCCT's own libraries refer to each other as @rpath/libTKFoo.dylib rather than
# by absolute path, so resolving only /opt/homebrew paths silently misses every
# second-level dependency. Map @rpath back to the Homebrew lib dirs.
resolve_dep() {
    case "$1" in
        /System/*|/usr/lib/*) return ;;                 # system, never bundle
        @rpath/*|@loader_path/*)
            local base="${1##*/}"
            for dir in "$OCC/lib" "$(brew --prefix)/lib"; do
                [ -e "$dir/$base" ] && { printf '%s\n' "$dir/$base"; return; }
            done
            ;;
        /opt/homebrew/*|/usr/local/*) printf '%s\n' "$1" ;;
    esac
}

changed=1
while [ "$changed" -eq 1 ]; do
    changed=0
    for bin in "$EXE" "$FRAMEWORKS"/*.dylib; do
        [ -e "$bin" ] || continue
        while read -r dep; do
            src="$(resolve_dep "$dep")"
            [ -n "$src" ] || continue
            base="$(basename "$src")"
            if [ ! -e "$FRAMEWORKS/$base" ]; then
                cp -L "$src" "$FRAMEWORKS/$base"
                chmod u+w "$FRAMEWORKS/$base"
                changed=1
            fi
        done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
    done
done

for bin in "$EXE" "$FRAMEWORKS"/*.dylib; do
    [ -e "$bin" ] || continue
    if [ "$bin" != "$EXE" ]; then
        install_name_tool -id "@rpath/$(basename "$bin")" "$bin" 2>/dev/null || true
    fi
    while read -r dep; do
        case "$dep" in
            /opt/homebrew/*|/usr/local/*)
                install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$bin" 2>/dev/null || true
                ;;
        esac
    done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
done
# The dylibs also load each other, so they need the rpath too.
for lib in "$FRAMEWORKS"/*.dylib; do
    [ -e "$lib" ] || continue
    install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

say "Bundled $(ls "$FRAMEWORKS" | wc -l | tr -d ' ') libraries ($(du -sh "$FRAMEWORKS" | cut -f1))"

# -------------------------------------------------------------- signing
# Ad-hoc ("-") since there is no Developer ID. Inside-out: libraries, then
# the extension, then the app.
say "Signing (ad-hoc)"
for lib in "$FRAMEWORKS"/*.dylib; do
    [ -e "$lib" ] || continue
    codesign --force --sign - --timestamp=none "$lib"
done
codesign --force --sign - --timestamp=none "$XPC"
codesign --force --sign - \
    --entitlements "$ROOT/src/qlext/entitlements.plist" \
    --timestamp=none "$APPEX"
codesign --force --sign - \
    --entitlements "$ROOT/src/app/entitlements.plist" \
    --timestamp=none "$APP"

codesign --verify --deep --strict "$APP"

say "Registering Quick Look extension and 3MF type with Launch Services"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

say "Built $APP — version $VERSION ($(du -sh "$APP" | cut -f1))"
