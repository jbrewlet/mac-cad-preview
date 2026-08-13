#ifndef READ_3MF_H
#define READ_3MF_H

#include <string>
#include <vector>

struct RawMesh {
    std::vector<float> positions;   // x,y,z triples
    std::vector<uint32_t> indices;  // triangle corner indices
};

// Reads triangle mesh data from a 3MF archive. Returns false and sets outError
// on failure.
bool read3mf(const std::string &path, RawMesh &outMesh, std::string &outError);

#endif
