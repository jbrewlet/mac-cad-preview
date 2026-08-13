// Standalone CLI so the geometry pipeline can be tested and timed without
// going anywhere near Quick Look.
//   ./cadprobe model.step [deflection]
//   ./cadprobe --version
#include "cadmesh.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Stamped by build.sh from the VERSION file; only unset for an ad-hoc compile.
#ifndef CADPROBE_VERSION
#define CADPROBE_VERSION "unknown"
#endif

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: cadprobe <file> [deflection]\n"
                             "       cadprobe --version\n");
        return 2;
    }
    if (std::strcmp(argv[1], "--version") == 0) {
        std::printf("cadprobe %s\n", CADPROBE_VERSION);
        return 0;
    }
    const double deflection = (argc > 2) ? std::atof(argv[2]) : -1.0;

    const auto start = std::chrono::steady_clock::now();
    CADMesh *mesh = cadmesh_load(argv[1], deflection);
    const auto elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();

    if (!mesh) {
        std::fprintf(stderr, "allocation failure\n");
        return 1;
    }
    if (mesh->error) {
        std::fprintf(stderr, "error: %s\n", mesh->error);
        cadmesh_free(mesh);
        return 1;
    }

    std::printf("ok        %.2f s\n", elapsed);
    std::printf("vertices  %u\n", mesh->vertexCount);
    std::printf("triangles %u\n", mesh->triangleCount);
    std::printf("bbox      [%.3f %.3f %.3f] .. [%.3f %.3f %.3f]\n",
                mesh->bboxMin[0], mesh->bboxMin[1], mesh->bboxMin[2],
                mesh->bboxMax[0], mesh->bboxMax[1], mesh->bboxMax[2]);
    std::printf("info      %s\n", mesh->info ? mesh->info : "(none)");

    cadmesh_free(mesh);
    return 0;
}
