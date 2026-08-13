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

4. Preview a file of each supported format — STEP, IGES and STL — from the built
   app. `tests/` has a spike model in STEP and STL. There is no automated test
   suite, so this is the gate.

5. Commit, tag and push. The tag goes on `main`:

   ```bash
   git commit -am "Release 0.2.0"
   git tag -a v0.2.0 -m "Mac CAD Preview 0.2.0"
   git push origin main
   git push origin v0.2.0
   ```

6. Publish the GitHub release at
   <https://github.com/jbrewlet/mac-cad-preview/releases/new>, choosing the tag
   just pushed and pasting that version's changelog section as the body.

   Do not attach a built `.app`. There is no Developer ID behind this project,
   so a downloaded ad-hoc signed app gets quarantined by macOS, and quarantined
   apps register their Quick Look extension unreliably. Shipping one would hand
   people an install that silently does not work.
