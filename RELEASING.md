# Releasing

This project is installed by building from source, so a release is a tagged
commit rather than an uploaded binary. Tagging still matters: it gives people a
known good revision to clone, and gives bug reports a version to name.

## Versioning

[Semantic Versioning](https://semver.org). While the major version is 0, the
minor version is bumped for breaking changes and the patch version for
everything else. A breaking change here means anything that invalidates an
existing install — the cache format, a bundle identifier, the minimum macOS
version, the set of supported file types.

`VERSION` at the repository root is the single source of truth. `build.sh`
stamps it into both `Info.plist` files and into `cadprobe` at build time, so the
version is never edited anywhere else.

## Steps

1. Bump `VERSION`.

2. Move the `Unreleased` entries in `CHANGELOG.md` under a new heading for the
   release, dated today, and add the two link definitions at the bottom of the
   file. Leave an empty `Unreleased` section behind.

3. Build and check the version came through:

   ```bash
   ./build.sh
   ./build/cadprobe --version
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
       "build/Mac CAD Preview.app/Contents/Info.plist"
   ```

4. Check the geometry pipeline against all three fixtures:

   ```bash
   for f in tests/spike.step tests/spike.iges tests/spike.stl; do
       ./build/cadprobe "$f" || echo "FAILED $f"
   done
   ```

   Each should report the same 40.0 × 24.0 × 26.0 bounding box. The STEP and
   IGES fixtures carry two colours; the STL one, which cannot carry colour, one.

5. Preview each of `tests/spike.step`, `tests/spike.iges`, `tests/spike.stl`
   `tests/spike.nc`, `tests/spike.tap` and `tests/spike.md` from the Finder
   with the built app installed. The G-code fixtures should show highlighted
   text, not a 3D view. The Markdown fixture should open rendered, and the
   **Source** segment should show the original text. Step 4 does not cover
   Quick Look itself — the extension registering, the panel appearing within the
   response timeout, and the controls responding. There is no automated test
   suite, so these two steps together are the gate.

6. Commit, tag and push. The tag goes on `main`:

   ```bash
   git commit -am "Release 0.2.0"
   git tag -a v0.2.0 -m "Mac CAD Preview 0.2.0"
   git push origin main
   git push origin v0.2.0
   ```

   Pushing the tag is what ships the release: `install.sh` installs the newest
   `v*` tag, so until it is pushed, anyone running the installer still gets the
   previous version. `install.sh` is fetched from `main`, so a change to the
   installer itself takes effect when `main` is pushed rather than when the tag
   is.

7. Build the disk image, and keep the SHA-256 it prints:

   ```bash
   ./package.sh
   ```

8. Publish the GitHub release at
   <https://github.com/jbrewlet/mac-cad-preview/releases/new>, choosing the tag
   just pushed and pasting that version's changelog section as the body. Attach
   `build/MacCADPreview-<version>.dmg` and quote its SHA-256 in the notes — with
   no Developer ID behind the app, that checksum is the only way someone can
   confirm what they downloaded is what was built.

   The README sends people to `releases/latest`, so a release without the `.dmg`
   attached leaves them with nothing to download.

9. Install from the release the way an end user does: download the `.dmg`, drag
   the app to Applications, approve it under Privacy & Security, and preview a
   file. This is the only step that covers the quarantine approval, which is
   what stands between a download and a working preview.

   Then check the source path still works, which skips quarantine entirely:

   ```bash
   ./install.sh
   ```

   It should pick up the tag just pushed, and the version on the app window
   should be the one being released.
