#!/usr/bin/env bash
# Builds the app and wraps it in a disk image for release.
#
#   ./package.sh
#
# Produces build/MacCADPreview-<version>.dmg, laid out the way macOS users
# expect: the app on the left, a link to Applications on the right, drag one
# onto the other. The instructions that ship inside the image cover the
# Gatekeeper approval, which is unavoidable without a Developer ID.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_NAME="Mac CAD Preview.app"
VOLUME_NAME="Mac CAD Preview $VERSION"
STAGING="$BUILD/dmg"
DMG="$BUILD/MacCADPreview-$VERSION.dmg"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

"$ROOT/build.sh"

[ -d "$BUILD/$APP_NAME" ] || {
    printf 'error: the build did not produce %s\n' "$APP_NAME" >&2
    exit 1
}

say "Staging the disk image"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$BUILD/$APP_NAME" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Named to sort first in the disk image window, since it has to be read before
# the app will open.
cat > "$STAGING/How to install.txt" <<EOF
Mac CAD Preview $VERSION

1. Drag "Mac CAD Preview" onto the Applications folder beside it.

2. Open your Applications folder and double click Mac CAD Preview.
   macOS will refuse to open it, saying it cannot check it for malicious
   software. That is expected: see below.

3. Open System Settings, go to Privacy & Security, and scroll down to the
   Security section. There will be a message about Mac CAD Preview being
   blocked, with an Open Anyway button. Click it and enter your password.

4. Mac CAD Preview opens, showing its version number. Quit it. That launch is
   all macOS needed; previews work whether or not the app is running.

5. Select a STEP, IGES, STL or 3MF file in the Finder and press the spacebar.

Why step 3 is necessary

Apple charges 99 US dollars a year for the certificate that would let this app
open without a warning. It is free software and does not have one, so macOS
cannot confirm who built it and asks you to confirm instead. Approving it once
is also what allows the preview to load, so the spacebar will do nothing until
step 3 is done.

The source is at https://github.com/jbrewlet/mac-cad-preview if you would
rather build it yourself and skip all of this.
EOF

say "Building $(basename "$DMG")"
rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

rm -rf "$STAGING"

hdiutil verify -quiet "$DMG"

say "Built $DMG ($(du -h "$DMG" | cut -f1))"
printf 'SHA-256: %s\n' "$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
