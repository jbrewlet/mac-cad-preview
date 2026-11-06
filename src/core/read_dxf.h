#ifndef READ_DXF_H
#define READ_DXF_H

#include "read_3mf.h"

#include <cstdint>
#include <set>
#include <string>
#include <vector>

// What an ASCII DXF contributes to a preview: shaded faces (3DFACE, SOLID,
// polyface and polygon meshes) and linework (lines, arcs, polylines, splines),
// with blocks expanded into model space.
struct DxfDrawing {
    RawMesh faces;
    std::vector<float> segments;    // x0,y0,z0, x1,y1,z1 per line segment
    std::string version;            // e.g. "AutoCAD 2018", empty if undeclared
    std::string units;              // e.g. "millimetres", empty if undeclared
    uint32_t entityCount = 0;       // model-space entities that produced geometry
    std::set<std::string> skippedTypes;  // TEXT, HATCH and others not drawn yet
    bool truncated = false;         // hit a size limit; the preview is partial
};

// Returns false and sets outError when the file cannot be read or holds
// nothing drawable. Never throws.
bool readDxf(const std::string &path, DxfDrawing &out, std::string &outError);

#endif
