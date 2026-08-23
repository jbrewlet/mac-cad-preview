# Fixtures

One mesh model in each 3D format: a 40 × 24 × 8 mm plate with 2 mm rounded
edges and a 12 mm bore, plus a separate 8 mm pin standing on it. The STEP,
IGES and STL fixtures describe the same pair of parts, so all three should
report a 40.0 × 24.0 × 26.0 bounding box. G-code fixtures are a text
preview of that same plate, not a mesh.

| File | Covers |
| --- | --- |
| `spike.step` | Trimmed NURBS tessellation, and two `styled_item` colours |
| `spike.iges` | The IGES reader, on the same geometry |
| `spike.stl` | The mesh reader, ASCII, no colour |

The rounded edges and the bore mean these carry toroidal, spherical and
cylindrical faces, not just planes — a reader that mishandles trimmed surfaces
fails visibly rather than subtly.

`make_fixtures.cpp` regenerates the three mesh fixtures; the compile line is in its header
comment. The output is committed, so it only needs running when the geometry
being covered changes.

| File | Covers |
| --- | --- |
| `spike.nc` | G-code text preview: comments, G/M words, axes, feed, speed, tool |
| `spike.tap` | Same program, other claimed extension |
| `spike.md` | Markdown preview: headings, emphasis, lists, a code block, a quote |
| `spike.zip` | Zip listing: two folders and a readme, same plate notes |
| `spike.rar` | RAR listing of the same tree |
| `spike.7z` | 7z listing of the same tree |

The G-code fixture is the same plate described as a short milling program, so the
highlighted preview has something recognisable to read. It is not fed to
`cadprobe`. The Markdown fixture covers the same part in prose, for the
rendered / source toggle. The archive fixtures pack that same readme so
spacebar shows a short folder tree rather than a 3D view.
