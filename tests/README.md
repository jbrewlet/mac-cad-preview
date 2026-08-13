# Fixtures

One model in each supported format: a 40 × 24 × 8 mm plate with 2 mm rounded
edges and a 12 mm bore, plus a separate 8 mm pin standing on it. All three
describe the same pair of parts, so all three should report a 40.0 × 24.0 ×
26.0 bounding box.

| File | Covers |
| --- | --- |
| `spike.step` | Trimmed NURBS tessellation, and two `styled_item` colours |
| `spike.iges` | The IGES reader, on the same geometry |
| `spike.stl` | The mesh reader, ASCII, no colour |

The rounded edges and the bore mean these carry toroidal, spherical and
cylindrical faces, not just planes — a reader that mishandles trimmed surfaces
fails visibly rather than subtly.

`make_fixtures.cpp` regenerates all three; the compile line is in its header
comment. The output is committed, so it only needs running when the geometry
being covered changes.
