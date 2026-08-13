// C API over OpenCASCADE, so Swift can call it without dealing with C++.
// Loads a CAD file, tessellates it, and hands back flat buffers ready to
// become a SceneKit geometry.
#ifndef CADMESH_H
#define CADMESH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// One run of triangles sharing a colour. Triangles are sorted by colour, so
// each group is a contiguous slice of `indices` and becomes a single SceneKit
// geometry element with its own material.
typedef struct CADMeshGroup {
    uint32_t firstIndex;    // offset into CADMesh.indices
    uint32_t indexCount;    // number of indices (3 per triangle)
    float    rgba[4];
} CADMeshGroup;

typedef struct CADMesh {
    float    *positions;    // 3 floats per vertex
    float    *normals;      // 3 floats per vertex
    uint32_t *indices;      // 3 per triangle, grouped by colour
    uint32_t  vertexCount;
    uint32_t  triangleCount;

    CADMeshGroup *groups;   // NULL if the file carried no colour information
    uint32_t      groupCount;

    float bboxMin[3];
    float bboxMax[3];

    // Human-readable model info for the overlay (units, solid/face counts,
    // STEP header fields). Owned by this struct; freed by cadmesh_free.
    char *info;

    // NULL on success, else a description of what went wrong.
    char *error;
} CADMesh;

// deflection <= 0 means "pick automatically from the bounding box".
// Returns NULL only on allocation failure; check ->error otherwise.
CADMesh *cadmesh_load(const char *path, double deflection);

void cadmesh_free(CADMesh *mesh);

#ifdef __cplusplus
}
#endif

#endif
