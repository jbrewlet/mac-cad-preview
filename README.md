# Mac CAD Preview

Preview CAD models in the Finder by pressing the spacebar, the same way you
already preview images and PDFs.

macOS has no idea what a STEP file is. Select one in the Finder, press space,
and you get a blank document icon. This adds a Quick Look extension that reads
the file, tessellates the real B-rep geometry, and shows an interactive 3D model
you can orbit, zoom and inspect without opening Fusion.

## Install

You need an Apple Silicon Mac running macOS 12 or later. You do not need to know
what any of the following does.

Open Terminal — press Command and Space, type `Terminal`, press Return — then
paste these three lines in, one at a time, pressing Return after each:

```bash
curl -fsSLO https://raw.githubusercontent.com/jbrewlet/mac-cad-preview/main/install.sh
less install.sh
bash install.sh
```

The middle line just shows you the script before you run it, which is worth
doing with anything you are about to paste into a terminal. Press `q` to close
it. If you would rather skip that and get on with it:

```bash
curl -fsSL https://raw.githubusercontent.com/jbrewlet/mac-cad-preview/main/install.sh | bash -s -- --yes
```

The installer checks your Mac can run the app, installs the one thing it depends
on, builds it, puts it in your Applications folder, and opens it once so macOS
notices it. Expect it to take several minutes the first time, most of that
spent downloading — the geometry library it builds against is a few hundred
megabytes. Everything it touches is on your own machine.

If it asks to install [Homebrew](https://brew.sh), that is a package manager for
macOS, and it is how the geometry library gets installed. Answering no stops the
install.

When it finishes, select a `.step`, `.iges` or `.stl` file in the Finder and
press the spacebar.

The window that opens during install is just there so macOS can find the
preview extension. You can quit it. Previews keep working without it running.

## Using it

| Action | Gesture |
|:-------|:--------|
| Orbit | Drag |
| Zoom | Scroll (zooms toward the pointer) |
| Pan | Two finger drag, or right button drag |

Zoom moves the camera toward whatever is under the pointer rather than the
centre of the window, and rotation re-anchors on the point you zoomed into, so
you can dive into a specific feature and keep turning around it.

Models are shown with Z pointing up, matching Fusion, SolidWorks and Inventor,
rather than SceneKit's default of Y up.

The bottom left corner shows the bounding box dimensions, the face count and the
triangle count. When a model has more than one colour, a **Model colours**
checkbox appears in the bottom right. Switch it off to see the whole part in a
single neutral finish, which is often easier to read shape from. It is hidden
for single colour models, where it would do nothing.

The first preview of a large file can take a few seconds. Every preview of that
same file afterwards is instant, because the result is cached.

## Supported formats

| Format | Extensions | Colours |
|:-------|:-----------|:--------|
| STEP | `.step`, `.stp`, `.p21` | yes |
| IGES | `.iges`, `.igs` | yes |
| STL | `.stl` | no (the format has none) |

Model colours are read from the file where the exporter wrote them. Not every
exporter writes them, so a part with no colour data falls back to neutral grey.

## Updating

Run the installer again. It replaces what is already there.

To see which version you have, open Mac CAD Preview from your Applications
folder — the version is on the window. [CHANGELOG.md](CHANGELOG.md) records what
changed in each release.

## Uninstall

```bash
rm -rf "/Applications/Mac CAD Preview.app"
rm -rf ~/Library/Containers/com.maccadpreview.quicklook
```

macOS removes the extension registration when the containing app goes away.

## If something is wrong

**Nothing happens, or the preview is blank.** Open Mac CAD Preview from your
Applications folder once, then try the preview again. That launch is what
registers the extension. To confirm macOS can see it:

```bash
pluginkit -m -i com.maccadpreview.quicklook
```

A leading `+` means it is registered and enabled. If you moved the app after
installing it, macOS may still be pointing at the old location:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Mac CAD Preview.app"
```

**One particular file will not open.** Some CAD tools write compressed data into
a plain `.step` file, which is not yet handled. Check with:

```bash
file yourpart.step
```

If it reports `gzip compressed data`, that is the known limitation below.

**Anything else.** The extension writes to the system log:

```bash
log stream --level info --predicate 'subsystem == "com.maccadpreview"'
```

Note that `log` is also a zsh builtin, so use `/usr/bin/log` if that command
behaves strangely.

## Known limitations

* gzip compressed STEP files are rejected rather than decompressed.
* No Finder icon thumbnails yet. Files still show a generic icon in icon view;
  the preview only appears on spacebar.
* No OBJ, PLY or 3MF support yet.
* Apple Silicon only. Intel is not supported.

## Support

This is free and always will be. If it saved you from opening Fusion just to
look at a part, you can [buy me a coffee](https://buymeacoffee.com/jbrw).

---

The rest of this is for people who want to build it themselves or understand how
it works.

## Building it yourself

The installer above does all of this for you. Doing it by hand:

```bash
xcode-select --install          # Command Line Tools; Xcode is not required
brew install opencascade
git clone https://github.com/jbrewlet/mac-cad-preview.git
cd mac-cad-preview
git checkout "$(git tag -l 'v*' --sort=-v:refname | head -n 1)"
./build.sh
```

Omit the `git checkout` to build the latest development revision instead of the
most recent release.

The build produces `build/Mac CAD Preview.app`. Move it where it should live,
then launch it once to register the extension:

```bash
mv "build/Mac CAD Preview.app" /Applications/
open "/Applications/Mac CAD Preview.app"
```

To check what a built bundle reports as its version:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "/Applications/Mac CAD Preview.app/Contents/Info.plist"
```

[RELEASING.md](RELEASING.md) covers cutting a release. `tests/` holds one model
per supported format, and `tests/README.md` describes what each covers.

### Why it builds instead of downloading a finished app

There is no Apple Developer ID behind this project, so any prebuilt app would be
ad-hoc signed. macOS quarantines ad-hoc signed apps downloaded from the internet,
and quarantined apps register their Quick Look extensions unreliably. Code you
compile yourself is never quarantined, so building from source is the install
path that actually works. The build itself takes a few seconds; the dependency
download is the slow part.

## Formats and tessellation

STEP and IGES are boundary representation formats: they describe trimmed NURBS
surfaces rather than triangles, so they have to be tessellated before anything
can draw them. That work is done by [OpenCASCADE](https://dev.opencascade.org).

STEP stores colours as `styled_item` entities, and they can be attached to a
whole solid or to an individual face. Triangles are grouped by colour and drawn
one draw call per group.

## Performance

Reading a STEP file is slow, and the cost is in parsing the text rather than in
meshing the geometry. A 56 MB assembly takes about 19 seconds. Lowering the
tessellation quality does not help, because that is not where the time goes.

So the tessellated result is cached. The first preview of a file pays the full
cost, and every preview after that is instant:

```
RC Draft.step (8.2 MB, 96,808 triangles)
  first open   3.15 s
  thereafter   0.00 s
```

The cache lives in the extension's sandbox container:

```
~/Library/Containers/com.maccadpreview.quicklook/Data/Library/Caches/MacCADPreview/
```

Entries are keyed on file path, size and modification time, so re-exporting a
part from your CAD tool invalidates the old entry automatically. The cache is
capped at 512 MB and evicts the least recently used entries first. To clear it:

```bash
rm -rf ~/Library/Containers/com.maccadpreview.quicklook/Data/Library/Caches/MacCADPreview
```

## How it works

`build.sh` assembles two bundles by hand, with no Xcode project involved:

* `Mac CAD Preview.app`, a container app whose only job is to be somewhere macOS
  can find the extension.
* `MacCADPreviewQL.appex` inside it, a Quick Look preview extension. Its entry
  point is `NSExtensionMain` rather than `main`.

The geometry core is C++ over OpenCASCADE, exposed to Swift through a small C
API (`src/core/cadmesh.h`). It reads the file, tessellates it, groups triangles
by colour, and returns flat buffers that become SceneKit geometry, one draw call
per colour.

Quick Look extensions are sandboxed and cannot load libraries from
`/opt/homebrew`, so `build.sh` copies every OpenCASCADE dylib the extension
needs into the bundle and rewrites the load commands to point inside it. That is
30 libraries and about 38 MB, walked automatically from the dependency graph.

Quick Look also kills extensions that take too long to respond, which a 19 second
parse would trip. So the panel is put on screen and reported ready immediately,
and the geometry is filled in from a background queue when it is available.

## Licence

MIT. See [LICENSE](LICENSE).

### Third party

This project links against, and its built app bundles, the following libraries.
None of them are modified.

| Library | Licence |
|:--------|:--------|
| OpenCASCADE Technology | LGPL 2.1, with the Open CASCADE exception |
| FreeType | FreeType Licence (BSD style) |
| libpng | PNG Reference Library Licence |
| Intel oneTBB | Apache 2.0 |

The repository itself contains no third party code. Those libraries arrive via
Homebrew when you build, and are copied into the app bundle at that point. If
you redistribute a built app, rather than the source, you take on the notice
requirements of the licences above.
