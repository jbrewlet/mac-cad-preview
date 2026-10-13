#include "read_3mf.h"

#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>
#include <zlib.h>

namespace {

// A 3MF file is untrusted input: every size, offset and index in it is
// attacker controlled. These caps bound what one preview can cost.
constexpr uint64_t kMaxFileBytes = 1024ull * 1024 * 1024;       // on disk
constexpr uint64_t kMaxInflatedBytes = 1024ull * 1024 * 1024;   // all entries, decompressed
constexpr size_t kMaxVertices = 30'000'000;                     // keeps every index well inside uint32
constexpr size_t kMaxIndices = 90'000'000;
constexpr size_t kMaxResolveCalls = 200'000;                    // component expansion work
constexpr size_t kMaxComponentDepth = 32;

struct ZipEntry {
    std::string name;
    std::vector<uint8_t> data;
};

struct Matrix3x4 {
    std::array<double, 12> m{1, 0, 0, 0,
                             0, 1, 0, 0,
                             0, 0, 1, 0};

    static Matrix3x4 identity() { return Matrix3x4(); }

    Matrix3x4 multiply(const Matrix3x4 &b) const {
        auto at = [](const Matrix3x4 &mat, int row, int col) -> double {
            if (row == 3) return col == 3 ? 1.0 : 0.0;
            return mat.m[static_cast<size_t>(row * 4 + col)];
        };
        Matrix3x4 r;
        for (int row = 0; row < 3; ++row) {
            for (int col = 0; col < 4; ++col) {
                double sum = 0.0;
                for (int k = 0; k < 4; ++k) {
                    sum += at(*this, row, k) * at(b, k, col);
                }
                r.m[static_cast<size_t>(row * 4 + col)] = sum;
            }
        }
        return r;
    }

    void apply(float &x, float &y, float &z) const {
        const double ox = x, oy = y, oz = z;
        x = static_cast<float>(m[0] * ox + m[1] * oy + m[2] * oz + m[3]);
        y = static_cast<float>(m[4] * ox + m[5] * oy + m[6] * oz + m[7]);
        z = static_cast<float>(m[8] * ox + m[9] * oy + m[10] * oz + m[11]);
    }
};

struct MeshChunk {
    std::vector<float> positions;
    std::vector<uint32_t> indices;
};

struct ObjectDef {
    MeshChunk mesh;
    std::vector<std::string> componentPaths;
    std::vector<int> componentObjectIds;
    std::vector<Matrix3x4> componentTransforms;
};

using ObjectMap = std::map<int, ObjectDef>;

// True when [offset, offset + length) lies inside a buffer of `size` bytes,
// without the addition being able to wrap.
bool inRange(size_t size, uint64_t offset, uint64_t length) {
    return offset <= size && length <= size - offset;
}

bool readFileBytes(const std::string &path, std::vector<uint8_t> &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    in.seekg(0, std::ios::end);
    const std::streamsize size = in.tellg();
    if (size <= 0 || static_cast<uint64_t>(size) > kMaxFileBytes) return false;
    in.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    return static_cast<bool>(in.read(reinterpret_cast<char *>(out.data()), size));
}

uint16_t readU16(const std::vector<uint8_t> &data, size_t offset) {
    return static_cast<uint16_t>(data[offset] | (data[offset + 1] << 8));
}

uint32_t readU32(const std::vector<uint8_t> &data, size_t offset) {
    return static_cast<uint32_t>(data[offset]) |
           (static_cast<uint32_t>(data[offset + 1]) << 8) |
           (static_cast<uint32_t>(data[offset + 2]) << 16) |
           (static_cast<uint32_t>(data[offset + 3]) << 24);
}

uint64_t readU64(const std::vector<uint8_t> &data, size_t offset) {
    return static_cast<uint64_t>(readU32(data, offset)) |
           (static_cast<uint64_t>(readU32(data, offset + 4)) << 32);
}

// Inflates in chunks rather than trusting the declared size up front, so a
// header that claims gigabytes for a few bytes of data costs nothing, and
// output beyond the declared size (or the remaining budget) is an error.
bool inflateBytes(const uint8_t *data, uint64_t compSize, uint64_t uncompSize,
                  uint64_t budget, std::vector<uint8_t> &out) {
    if (uncompSize > budget) return false;
    if (compSize > std::numeric_limits<uInt>::max()) return false;

    out.clear();
    out.reserve(static_cast<size_t>(uncompSize));
    z_stream stream{};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    stream.next_in = const_cast<Bytef *>(data);
    stream.avail_in = static_cast<uInt>(compSize);

    std::array<uint8_t, 64 * 1024> chunk;
    int rc = Z_OK;
    while (rc == Z_OK) {
        stream.next_out = chunk.data();
        stream.avail_out = static_cast<uInt>(chunk.size());
        rc = inflate(&stream, Z_NO_FLUSH);
        if (rc != Z_OK && rc != Z_STREAM_END) break;
        const size_t produced = chunk.size() - stream.avail_out;
        if (out.size() + produced > uncompSize) {
            rc = Z_DATA_ERROR;
            break;
        }
        out.insert(out.end(), chunk.data(), chunk.data() + produced);
    }
    inflateEnd(&stream);
    return rc == Z_STREAM_END;
}

void readZip64Extra(const std::vector<uint8_t> &zip, size_t extraStart, size_t extraLen,
                    uint64_t &compSize, uint64_t &uncompSize, uint64_t &localOffset) {
    size_t pos = extraStart;
    const size_t extraEnd = extraStart + extraLen;
    while (pos + 4 <= extraEnd) {
        const uint16_t hdrId = readU16(zip, pos);
        const uint16_t hdrSz = readU16(zip, pos + 2);
        pos += 4;
        if (hdrSz > extraEnd - pos) break;
        if (hdrId == 0x0001) {
            size_t p = pos;
            const size_t fieldEnd = pos + hdrSz;
            if (uncompSize == 0xFFFFFFFFu) {
                if (p + 8 > fieldEnd) return;
                uncompSize = readU64(zip, p);
                p += 8;
            }
            if (compSize == 0xFFFFFFFFu) {
                if (p + 8 > fieldEnd) return;
                compSize = readU64(zip, p);
                p += 8;
            }
            if (localOffset == 0xFFFFFFFFu) {
                if (p + 8 > fieldEnd) return;
                localOffset = readU64(zip, p);
            }
        }
        pos += hdrSz;
    }
}

bool extractLocalEntry(const std::vector<uint8_t> &zip, uint64_t localOffset,
                       uint64_t compSize, uint64_t uncompSize, uint64_t budget,
                       std::vector<uint8_t> &out) {
    if (!inRange(zip.size(), localOffset, 30)) return false;
    const size_t local = static_cast<size_t>(localOffset);
    if (readU32(zip, local) != 0x04034b50) return false;

    const uint16_t nameLen = readU16(zip, local + 26);
    const uint16_t extraLen = readU16(zip, local + 28);
    const uint64_t headerEnd = localOffset + 30 + nameLen + extraLen;

    if (!inRange(zip.size(), headerEnd, compSize)) return false;
    const uint8_t *payload = zip.data() + headerEnd;
    const uint16_t method = readU16(zip, local + 8);
    if (method == 0) {
        if (compSize > budget) return false;
        out.assign(payload, payload + compSize);
        return true;
    }
    if (method == 8) {
        return inflateBytes(payload, compSize, uncompSize, budget, out);
    }
    return false;
}

// Only the parts a 3MF reader needs are decompressed; anything else in the
// archive (thumbnails, slicer metadata, padding) is never inflated.
bool isWantedEntry(const std::string &name) {
    if (name == "_rels/.rels") return true;
    return name.size() >= 6 && name.compare(name.size() - 6, 6, ".model") == 0;
}

bool extractZip(const std::vector<uint8_t> &zip, std::map<std::string, ZipEntry> &out) {
    if (zip.size() < 22) return false;

    // The end record sits in the last 22 bytes plus at most a 64 KB comment.
    const size_t lowest = zip.size() > 22 + 0xFFFF ? zip.size() - 22 - 0xFFFF : 0;
    size_t eocd = zip.size() - 22;
    while (eocd > lowest && readU32(zip, eocd) != 0x06054b50) --eocd;
    if (readU32(zip, eocd) != 0x06054b50) return false;

    uint64_t cdOffset = readU32(zip, eocd + 16);
    uint64_t cdSize = readU32(zip, eocd + 12);

    if (cdOffset == 0xFFFFFFFFu) {
        // The Zip64 locator immediately precedes the end record.
        if (eocd < 20) return false;
        const size_t locator = eocd - 20;
        if (readU32(zip, locator) != 0x07064b50) return false;
        const uint64_t z64 = readU64(zip, locator + 8);
        if (!inRange(zip.size(), z64, 56)) return false;
        if (readU32(zip, static_cast<size_t>(z64)) != 0x06064b50) return false;
        cdOffset = readU64(zip, static_cast<size_t>(z64) + 48);
        cdSize = readU64(zip, static_cast<size_t>(z64) + 40);
    }

    if (cdOffset >= zip.size()) return false;

    size_t offset = static_cast<size_t>(cdOffset);
    const size_t end = inRange(zip.size(), cdOffset, cdSize)
        ? static_cast<size_t>(cdOffset + cdSize) : zip.size();
    uint64_t budget = kMaxInflatedBytes;

    while (inRange(end, offset, 46)) {
        if (readU32(zip, offset) != 0x02014b50) break;

        uint64_t compSize = readU32(zip, offset + 20);
        uint64_t uncompSize = readU32(zip, offset + 24);
        const uint16_t nameLen = readU16(zip, offset + 28);
        const uint16_t extraLen = readU16(zip, offset + 30);
        const uint16_t commentLen = readU16(zip, offset + 32);
        uint64_t localOffset = readU32(zip, offset + 42);

        const size_t recordSize = 46 + size_t(nameLen) + extraLen + commentLen;
        if (!inRange(zip.size(), offset, recordSize)) break;

        const std::string name(reinterpret_cast<const char *>(&zip[offset + 46]), nameLen);
        if (isWantedEntry(name)) {
            if (compSize == 0xFFFFFFFFu || uncompSize == 0xFFFFFFFFu ||
                localOffset == 0xFFFFFFFFu) {
                readZip64Extra(zip, offset + 46 + nameLen, extraLen,
                               compSize, uncompSize, localOffset);
            }
            std::vector<uint8_t> data;
            if (extractLocalEntry(zip, localOffset, compSize, uncompSize, budget, data)) {
                budget -= data.size();
                out[name] = ZipEntry{name, std::move(data)};
            }
        }
        offset += recordSize;
    }

    return !out.empty();
}

std::string normalizePath(std::string path) {
    if (!path.empty() && path[0] == '/') path.erase(0, 1);
    return path;
}

std::string attrValue(const std::string &tag, const char *key) {
    const std::string quoted = std::string(key) + "=\"";
    size_t pos = tag.find(quoted);
    if (pos == std::string::npos) {
        const std::string spaced = std::string(key) + " = \"";
        pos = tag.find(spaced);
        if (pos == std::string::npos) return "";
        pos += spaced.size();
    } else {
        pos += quoted.size();
    }
    const size_t end = tag.find('"', pos);
    if (end == std::string::npos) return "";
    return tag.substr(pos, end - pos);
}

Matrix3x4 parseTransform(const std::string &value) {
    Matrix3x4 t;
    if (value.empty()) return t;
    std::vector<double> vals;
    std::istringstream in(value);
    double v = 0.0;
    while (vals.size() < 12 && in >> v) {
        if (!std::isfinite(v)) return t;
        vals.push_back(v);
    }
    if (vals.size() < 12) return t;

    // Slicers (Bambu, Prusa, etc.) write nine rotation values then tx ty tz.
    // The spec interleaves translation at indices 3, 7 and 11 instead.
    const bool specLayout = (std::abs(vals[9]) < 1e-9 && std::abs(vals[10]) < 1e-9 &&
                             (std::abs(vals[3]) > 1e-9 || std::abs(vals[7]) > 1e-9 ||
                              std::abs(vals[11]) > 1e-9));
    const bool slicerLayout = !specLayout;
    if (slicerLayout) {
        t.m[0] = vals[0];  t.m[1] = vals[1];  t.m[2] = vals[2];  t.m[3] = vals[9];
        t.m[4] = vals[3];  t.m[5] = vals[4];  t.m[6] = vals[5];  t.m[7] = vals[10];
        t.m[8] = vals[6];  t.m[9] = vals[7];  t.m[10] = vals[8]; t.m[11] = vals[11];
    } else {
        for (int i = 0; i < 12; ++i) t.m[static_cast<size_t>(i)] = vals[static_cast<size_t>(i)];
    }
    return t;
}

bool tagIs(const std::string &tag, const char *name) {
    const std::string open = std::string("<") + name;
    if (tag.rfind(open, 0) != 0) return false;
    const size_t next = open.size();
    if (tag.size() <= next) return false;
    const char c = tag[next];
    return c == ' ' || c == '/' || c == '>' || c == '\t';
}

// Non-finite coordinates ("nan", "inf", 1e999) are read as 0 so they cannot
// poison the bounding box or the camera.
float parseAttr(const std::string &tag, const char *key) {
    const std::string value = attrValue(tag, key);
    if (value.empty()) return 0.0f;
    try {
        const float f = std::stof(value);
        return std::isfinite(f) ? f : 0.0f;
    } catch (...) {
        return 0.0f;
    }
}

int parseIntAttr(const std::string &tag, const char *key) {
    const std::string value = attrValue(tag, key);
    if (value.empty()) return -1;
    try {
        return std::stoi(value);
    } catch (...) {
        return -1;
    }
}

ObjectMap parseObjectsFromXml(const std::string &xml) {
    ObjectMap objects;
    int currentId = -1;
    bool inMesh = false;

    for (size_t i = 0; i < xml.size();) {
        const size_t lt = xml.find('<', i);
        if (lt == std::string::npos) break;
        const size_t gt = xml.find('>', lt);
        if (gt == std::string::npos) break;
        const std::string tag = xml.substr(lt, gt - lt + 1);

        if (tagIs(tag, "object")) {
            const int id = parseIntAttr(tag, "id");
            if (id >= 0) {
                currentId = id;
                objects[currentId] = ObjectDef{};
            }
        } else if (tagIs(tag, "mesh")) {
            inMesh = true;
        } else if (tag.find("</mesh>") == 0) {
            inMesh = false;
        } else if (inMesh && currentId >= 0) {
            if (tagIs(tag, "vertex")) {
                auto &mesh = objects[currentId].mesh;
                mesh.positions.push_back(parseAttr(tag, "x"));
                mesh.positions.push_back(parseAttr(tag, "y"));
                mesh.positions.push_back(parseAttr(tag, "z"));
            } else if (tagIs(tag, "triangle")) {
                auto &mesh = objects[currentId].mesh;
                const int v1 = parseIntAttr(tag, "v1");
                const int v2 = parseIntAttr(tag, "v2");
                const int v3 = parseIntAttr(tag, "v3");
                if (v1 >= 0 && v2 >= 0 && v3 >= 0) {
                    mesh.indices.push_back(static_cast<uint32_t>(v1));
                    mesh.indices.push_back(static_cast<uint32_t>(v2));
                    mesh.indices.push_back(static_cast<uint32_t>(v3));
                }
            }
        } else if (tagIs(tag, "component") && currentId >= 0) {
            auto &obj = objects[currentId];
            std::string path = attrValue(tag, "p:path");
            if (path.empty()) path = attrValue(tag, "path");
            obj.componentPaths.push_back(normalizePath(path));
            const int refId = parseIntAttr(tag, "objectid");
            obj.componentObjectIds.push_back(refId >= 0 ? refId : 0);
            obj.componentTransforms.push_back(parseTransform(attrValue(tag, "transform")));
        }

        i = gt + 1;
    }

    return objects;
}

// Returns false once the output would exceed the vertex or index caps.
// Triangles that name a vertex the object does not have are dropped: their
// indices would otherwise reach memory outside the vertex buffer.
bool appendMesh(const MeshChunk &chunk, const Matrix3x4 &transform, RawMesh &out) {
    if (chunk.positions.empty() || chunk.indices.empty()) return true;

    const size_t vertexCount = chunk.positions.size() / 3;
    const size_t base = out.positions.size() / 3;
    if (vertexCount > kMaxVertices - base) return false;
    if (chunk.indices.size() > kMaxIndices - out.indices.size()) return false;

    for (size_t i = 0; i + 2 < chunk.positions.size(); i += 3) {
        float x = chunk.positions[i];
        float y = chunk.positions[i + 1];
        float z = chunk.positions[i + 2];
        transform.apply(x, y, z);
        out.positions.push_back(std::isfinite(x) ? x : 0.0f);
        out.positions.push_back(std::isfinite(y) ? y : 0.0f);
        out.positions.push_back(std::isfinite(z) ? z : 0.0f);
    }
    for (size_t i = 0; i + 2 < chunk.indices.size(); i += 3) {
        const uint32_t a = chunk.indices[i];
        const uint32_t b = chunk.indices[i + 1];
        const uint32_t c = chunk.indices[i + 2];
        if (a >= vertexCount || b >= vertexCount || c >= vertexCount) continue;
        out.indices.push_back(static_cast<uint32_t>(base + a));
        out.indices.push_back(static_cast<uint32_t>(base + b));
        out.indices.push_back(static_cast<uint32_t>(base + c));
    }
    return true;
}

struct ResolveState {
    const std::map<std::string, std::string> &models;
    std::map<std::string, ObjectMap> parsed;            // each model file parsed once
    std::vector<std::pair<std::string, int>> stack;     // (model path, object id) being expanded
    size_t calls = 0;
    bool overBudget = false;

    const ObjectMap *objectsIn(const std::string &path) {
        const auto cached = parsed.find(path);
        if (cached != parsed.end()) return &cached->second;
        const auto model = models.find(path);
        if (model == models.end()) return nullptr;
        return &parsed.emplace(path, parseObjectsFromXml(model->second)).first->second;
    }
};

void resolveObject(ResolveState &state, const std::string &modelPath, int objectId,
                   const Matrix3x4 &transform, RawMesh &out) {
    if (state.overBudget) return;
    if (++state.calls > kMaxResolveCalls || state.stack.size() >= kMaxComponentDepth) {
        state.overBudget = true;
        return;
    }
    for (const auto &seen : state.stack) {
        if (seen.first == modelPath && seen.second == objectId) return;   // cycle
    }

    const ObjectMap *objects = state.objectsIn(modelPath);
    if (!objects) return;
    const auto objIt = objects->find(objectId);
    if (objIt == objects->end()) return;
    const ObjectDef &obj = objIt->second;

    if (!appendMesh(obj.mesh, transform, out)) {
        state.overBudget = true;
        return;
    }

    state.stack.emplace_back(modelPath, objectId);
    for (size_t i = 0; i < obj.componentPaths.size() && !state.overBudget; ++i) {
        // A component with no path refers to an object in the same model file.
        const std::string &path = obj.componentPaths[i].empty() ? modelPath
                                                                : obj.componentPaths[i];
        const Matrix3x4 next = transform.multiply(obj.componentTransforms[i]);
        resolveObject(state, path, obj.componentObjectIds[i], next, out);
    }
    state.stack.pop_back();
}

std::string findRootModelPath(const std::map<std::string, ZipEntry> &entries) {
    const auto rels = entries.find("_rels/.rels");
    if (rels != entries.end()) {
        const std::string xml(reinterpret_cast<const char *>(rels->second.data.data()),
                              rels->second.data.size());
        for (size_t i = 0; i < xml.size();) {
            const size_t lt = xml.find("<Relationship ", i);
            if (lt == std::string::npos) break;
            const size_t gt = xml.find("/>", lt);
            if (gt == std::string::npos) break;
            const std::string tag = xml.substr(lt, gt - lt + 2);
            if (tag.find("3dmodel") != std::string::npos) {
                return normalizePath(attrValue(tag, "Target"));
            }
            i = gt + 2;
        }
    }
    if (entries.count("3D/3dmodel.model")) return "3D/3dmodel.model";
    for (const auto &entry : entries) {
        if (entry.first.size() >= 13 &&
            entry.first.compare(entry.first.size() - 13, 13, "3dmodel.model") == 0) {
            return entry.first;
        }
    }
    return "";
}

bool buildMeshFromArchive(const std::map<std::string, ZipEntry> &entries,
                          RawMesh &outMesh, std::string &outError) {
    std::map<std::string, std::string> models;
    for (const auto &entry : entries) {
        if (entry.first.size() < 6) continue;
        if (entry.first.compare(entry.first.size() - 6, 6, ".model") != 0) continue;
        models[entry.first] = std::string(reinterpret_cast<const char *>(entry.second.data.data()),
                                          entry.second.data.size());
    }
    if (models.empty()) {
        outError = "This 3MF file does not contain a readable model.";
        return false;
    }

    const std::string rootPath = findRootModelPath(entries);
    if (rootPath.empty() || !models.count(rootPath)) {
        outError = "This 3MF file does not contain a readable model.";
        return false;
    }

    const std::string &rootXml = models[rootPath];
    ResolveState state{models};

    for (size_t i = 0; i < rootXml.size() && !state.overBudget;) {
        const size_t lt = rootXml.find('<', i);
        if (lt == std::string::npos) break;
        const size_t gt = rootXml.find('>', lt);
        if (gt == std::string::npos) break;
        const std::string tag = rootXml.substr(lt, gt - lt + 1);
        if (tagIs(tag, "item")) {
            const int objectId = parseIntAttr(tag, "objectid");
            if (objectId >= 0) {
                const Matrix3x4 transform = parseTransform(attrValue(tag, "transform"));
                resolveObject(state, rootPath, objectId, transform, outMesh);
            }
        }
        i = gt + 1;
    }

    if (!state.overBudget && (outMesh.positions.empty() || outMesh.indices.empty())) {
        // Some exporters omit a build section — merge every mesh object we found.
        for (const auto &entry : models) {
            const ObjectMap *objectsInFile = state.objectsIn(entry.first);
            if (!objectsInFile) continue;
            for (const auto &objEntry : *objectsInFile) {
                if (!appendMesh(objEntry.second.mesh, Matrix3x4::identity(), outMesh)) {
                    state.overBudget = true;
                    break;
                }
            }
            if (state.overBudget) break;
        }
    }

    if (state.overBudget) {
        outMesh = RawMesh{};
        outError = "This 3MF file is too large or too complex to preview.";
        return false;
    }
    if (outMesh.positions.empty() || outMesh.indices.empty()) {
        outError = "This 3MF file contained no mesh geometry.";
        return false;
    }
    return true;
}

} // namespace

bool read3mf(const std::string &path, RawMesh &outMesh, std::string &outError) {
    std::vector<uint8_t> zip;
    if (!readFileBytes(path, zip)) {
        outError = "Could not open this 3MF file, or it is too large to preview.";
        return false;
    }

    std::map<std::string, ZipEntry> entries;
    if (!extractZip(zip, entries)) {
        outError = "This 3MF file does not contain a readable model.";
        return false;
    }

    return buildMeshFromArchive(entries, outMesh, outError);
}
