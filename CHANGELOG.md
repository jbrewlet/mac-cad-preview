# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is 0, the minor version is bumped for breaking changes
and the patch version for everything else.

## [Unreleased]

## [0.3.0] - 2026-08-13

### Added

* Quick Look preview for G-code (`.nc`, `.tap`) with syntax colouring for
  G/M words, axis addresses, feed/speed, tools, line numbers and comments.
* G-code font size can be changed in the preview (**A−** / **A+**) or in the
  host app **Settings** window, and is saved for the next spacebar.
* Settings for 3D and G-code previews: model-colour default, zoom direction
  and target, up axis, initial view, G-code font size, line wrapping and
  colour theme. A **Settings** link on every preview opens the same window.
* **Edges** overlay on 3D previews (sharp and boundary edges on the shaded
  model) and an **Ortho** camera toggle. Both are saved, and have defaults
  in Settings.
* Click the bounding-box dimensions to copy them.
* The initial 3D camera frames the whole model with a light margin, instead
  of sitting at a fixed multiple of the longest side.
* Bounding box, dimensions and camera fit use the tessellated triangles
  rather than the untrimmed NURBS hull, so Rhino STEP parts no longer
  appear as a speck in a huge empty frame.
* Load status names the stage — parsing, tessellating, or reading a mesh —
  and warns that the first preview of a large STEP or IGES file can take a
  while.
* `doctor.sh`, a read-only diagnostic for previews that do not appear. It
  checks the machine, the install, quarantine, the extension's sandbox and
  registration, and how macOS classifies a given file.
* Quick Look also handles STEP and 3MF files that macOS has labelled as
  Shapr3D's types, so a machine with Shapr3D installed still gets a preview.

### Changed

* The host app no longer claims to be the default opener for `.3mf`. Quick
  Look is unchanged; double-clicking a `.3mf` no longer opens the version
  window.
* README troubleshooting leads with `doctor.sh`, covers the Quick Look
  switch under Login Items & Extensions, and no longer treats a leading
  `+` as the only healthy `pluginkit` state.

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

[Unreleased]: https://github.com/jbrewlet/mac-cad-preview/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.3.0
[0.2.0]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.2.0
[0.1.0]: https://github.com/jbrewlet/mac-cad-preview/releases/tag/v0.1.0
