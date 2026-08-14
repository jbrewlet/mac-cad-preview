# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is 0, the minor version is bumped for breaking changes
and the patch version for everything else.

## [Unreleased]

## [0.2.1] - 2026-08-13

### Fixed

* Previews for STEP and 3MF files on Macs with Shapr3D installed. Shapr3D
  exports its own types for `.step` and `.3mf`, and whichever app owns a type
  decides what a file is; Quick Look then matches that type exactly and does not
  fall back to a parent type, so those files were never offered to the extension
  and the spacebar did nothing at all. `com.shapr3d.step` and
  `com.shapr3d.3d-manufacturing.3mf` are now handled.
* Mac CAD Preview no longer makes itself the default application for `.3mf`. It
  declared a document type it cannot open, so double clicking a 3MF opened a
  window showing only the version number. A Quick Look extension needs the type
  to exist, not a handler for it, so the declaration is gone.

### Added

* `doctor.sh`, a read-only diagnostic for previews that do not appear. It checks
  the machine, the install location, quarantine, the signature, the extension's
  sandbox entitlement and registration, and how macOS classifies a given file,
  then prints each problem with the command that fixes it. It also lists every
  app on the Mac that claims a CAD extension and flags any type the extension
  does not handle, which is the only way to discover those identifiers: they
  belong to other apps and cannot be known in advance.

### Changed

* README troubleshooting leads with `doctor.sh`, covers the Quick Look switch
  under System Settings → General → Login Items & Extensions, and no longer
  claims a leading `+` is the only healthy `pluginkit` state — a blank first
  column is the normal one.

## [0.2.0] - 2026-08-13

### Added

* **Open in Fusion** button on STEP and IGES Quick Look previews when Autodesk
  Fusion is installed. A sandboxed extension cannot launch other apps directly,
  so an on-demand XPC helper embedded in the extension opens the file through
  Launch Services and reuses a running Fusion instance when possible.
* Basic **3MF** (`.3mf`) mesh preview support.
* Version number shown in the host app welcome window, read from the bundle.

### Changed

* Known limitations updated: 3MF is supported; OBJ and PLY are still not.

## [0.1.0] - 2026-08-13

First release.

### Added

* Quick Look preview extension for STEP (`.step`, `.stp`, `.p21`), IGES
  (`.iges`, `.igs`) and STL (`.stl`) files. Press space in the Finder to get an
  interactive 3D model rather than a blank document icon.
* Real B-rep tessellation through OpenCASCADE, so STEP and IGES trimmed NURBS
  surfaces are meshed rather than approximated.
* Per-solid and per-face colours read from STEP `styled_item` entities, drawn
  one draw call per colour, with a **Model colours** toggle for models that have
  more than one. Parts with no colour data fall back to neutral grey.
* Orbit, zoom and pan controls. Zoom moves the camera toward the pointer and
  rotation re-anchors on the point zoomed into.
* Z-up orientation, matching Fusion, SolidWorks and Inventor rather than
  SceneKit's default Y-up.
* Bounding box dimensions, face count and triangle count shown in the corner of
  the preview.
* On-disk tessellation cache keyed on file path, size and modification time.
  First preview pays the parse cost, later ones are instant. Capped at 512 MB
  with least-recently-used eviction.
* Asynchronous geometry loading, so a slow parse does not trip Quick Look's
  extension response timeout.
* A downloadable disk image, built by `package.sh`, so installing is drag the
  app to Applications and approve it once under Privacy & Security. The bundle
  is self contained, so nothing else has to be installed first.
* `install.sh`, a single command install from source for anyone who would rather
  compile it, which also avoids the Gatekeeper approval: it checks the machine is
  supported, gets Homebrew and OpenCASCADE if they are missing, builds, installs
  to `/Applications`, and registers the extension.
* `build.sh`, which builds both bundles without an Xcode project, walks the
  OpenCASCADE dependency graph to bundle every dylib the sandboxed extension
  needs, and ad-hoc signs the result.
* `cadprobe`, a CLI for exercising and timing the geometry pipeline without
  Quick Look in the way.
* A Buy Me a Coffee link, on the host app window and in the README.

### Known limitations

* Apple Silicon only. Homebrew's OpenCASCADE is arm64-only.
* gzip compressed STEP files are rejected rather than decompressed.
* No Finder icon thumbnails. The preview only appears on spacebar.
* No OBJ, PLY or 3MF support.

[Unreleased]: https://github.com/jbrewlet/mac-cad-preview/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.2.1
[0.2.0]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.2.0
[0.1.0]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.1.0
