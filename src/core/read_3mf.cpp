#include "read_3mf.h"

#include <array>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>
#include <zlib.h>

namespace {

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

bool readFileBytes(const std::string &path, std::vector<uint8_t> &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    in.seekg(0, std::ios::end);
    const std::streamsize size = in.tellg();
    if (size <= 0) return false;
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

bool inflateBytes(const uint8_t *data, size_t compSize, size_t uncompSize,
                  std::vector<uint8_t> &out) {
    out.resize(uncompSize);
    z_stream stream{};
    stream.next_in = const_cast<Bytef *>(data);
    stream.avail_in = static_cast<uInt>(compSize);
    stream.next_out = out.data();
    stream.avail_out = static_cast<uInt>(uncompSize);
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    const int rc = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    return rc == Z_STREAM_END || rc == Z_OK;
}

void readZip64Extra(const std::vector<uint8_t> &extra, uint64_t &compSize,
                    uint64_t &uncompSize, bool includeLocalOffset,
                    uint64_t &localOffset) {
    size_t pos = 0;
    while (pos + 4 <= extra.size()) {
        const uint16_t hdrId = readU16(extra, pos);
        const uint16_t hdrSz = readU16(extra, pos + 2);
        pos += 4;
        if (pos + hdrSz > extra.size()) break;
        if (hdrId == 0x0001) {
            size_t p = pos;
            if (uncompSize == 0xFFFFFFFFu) {
                uncompSize = readU64(extra, p);
                p += 8;
            }
            if (compSize == 0xFFFFFFFFu) {
                compSize = readU64(extra, p);
                p += 8;
            }
            if (includeLocalOffset && localOffset == 0xFFFFFFFFu) {
                localOffset = readU64(extra, p);
            }
        }
        pos += hdrSz;
    }
}

bool extractLocalEntry(const std::vector<uint8_t> &zip, uint64_t localOffset,
                       uint64_t compSize, uint64_t uncompSize,
                       std::vector<uint8_t> &out) {
    if (localOffset + 30 > zip.size()) return false;
    if (readU32(zip, static_cast<size_t>(localOffset)) != 0x04034b50) return false;

    const uint16_t nameLen = readU16(zip, static_cast<size_t>(localOffset) + 26);
    const uint16_t extraLen = readU16(zip, static_cast<size_t>(localOffset) + 28);
    const size_t headerEnd = static_cast<size_t>(localOffset) + 30 + nameLen + extraLen;

    if (headerEnd + compSize > zip.size()) return false;
    const uint8_t *payload = zip.data() + headerEnd;
    const uint16_t method = readU16(zip, static_cast<size_t>(localOffset) + 8);
    if (method == 0) {
        out.assign(payload, payload + compSize);
        return out.size() == compSize;
    }
    if (method == 8) {
        return inflateBytes(payload, static_cast<size_t>(compSize),
                            static_cast<size_t>(uncompSize), out);
    }
    return false;
}

bool extractZip(const std::vector<uint8_t> &zip, std::map<std::string, ZipEntry> &out) {
    if (zip.size() < 22) return false;

    size_t eocd = zip.size() - 22;
    while (eocd > 0 && readU32(zip, eocd) != 0x06054b50) --eocd;
    if (readU32(zip, eocd) != 0x06054b50) return false;

    uint64_t cdOffset = readU32(zip, eocd + 16);
    uint64_t cdSize = readU32(zip, eocd + 12);

    if (cdOffset == 0xFFFFFFFFu) {
        size_t locator = eocd;
        while (locator > 0 && readU32(zip, locator) != 0x07064b50) --locator;
        if (readU32(zip, locator) != 0x07064b50) return false;
        const size_t z64 = static_cast<size_t>(readU64(zip, locator + 8));
        if (z64 + 56 > zip.size() || readU32(zip, z64) != 0x06064b50) return false;
        cdOffset = readU64(zip, z64 + 48);
        cdSize = readU64(zip, z64 + 40);
    }

    if (cdOffset >= zip.size()) return false;

    size_t offset = static_cast<size_t>(cdOffset);
    const size_t end = offset + static_cast<size_t>(cdSize);
    while (offset + 46 <= end && offset + 46 <= zip.size()) {
        if (readU32(zip, offset) != 0x02014b50) break;

        uint64_t compSize = readU32(zip, offset + 20);
        uint64_t uncompSize = readU32(zip, offset + 24);
        const uint16_t nameLen = readU16(zip, offset + 28);
        const uint16_t extraLen = readU16(zip, offset + 30);
        const uint16_t commentLen = readU16(zip, offset + 32);
        uint64_t localOffset = readU32(zip, offset + 42);

        if (compSize == 0xFFFFFFFFu || uncompSize == 0xFFFFFFFFu ||
            localOffset == 0xFFFFFFFFu) {
            readZip64Extra(std::vector<uint8_t>(zip.begin() + offset + 46 + nameLen,
                                                zip.begin() + offset + 46 + nameLen + extraLen),
                           compSize, uncompSize, true, localOffset);
        }

        const std::string name(reinterpret_cast<const char *>(&zip[offset + 46]),
                               nameLen);
        std::vector<uint8_t> data;
        if (!extractLocalEntry(zip, localOffset, compSize, uncompSize, data)) {
            offset += 46 + nameLen + extraLen + commentLen;
            continue;
        }
        out[name] = ZipEntry{name, std::move(data)};
        offset += 46 + nameLen + extraLen + commentLen;
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
    while (in >> v) vals.push_back(v);
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

float parseAttr(const std::string &tag, const char *key) {
    const std::string value = attrValue(tag, key);
    if (value.empty()) return 0.0f;
    try {
        return std::stof(value);
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

MeshChunk parseMeshFromXml(const std::string &xml) {
    MeshChunk chunk;
    for (size_t i = 0; i < xml.size();) {
        const size_t lt = xml.find('<', i);
        if (lt == std::string::npos) break;
        const size_t gt = xml.find('>', lt);
        if (gt == std::string::npos) break;
        const std::string tag = xml.substr(lt, gt - lt + 1);

        if (tagIs(tag, "vertex")) {
            chunk.positions.push_back(parseAttr(tag, "x"));
            chunk.positions.push_back(parseAttr(tag, "y"));
            chunk.positions.push_back(parseAttr(tag, "z"));
        } else if (tagIs(tag, "triangle")) {
            const int v1 = parseIntAttr(tag, "v1");
            const int v2 = parseIntAttr(tag, "v2");
            const int v3 = parseIntAttr(tag, "v3");
            if (v1 < 0 || v2 < 0 || v3 < 0) continue;
            chunk.indices.push_back(static_cast<uint32_t>(v1));
            chunk.indices.push_back(static_cast<uint32_t>(v2));
            chunk.indices.push_back(static_cast<uint32_t>(v3));
        }

        i = gt + 1;
    }
    return chunk;
}

std::map<int, ObjectDef> parseObjectsFromXml(const std::string &xml) {
    std::map<int, ObjectDef> objects;
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
                if (v1 < 0 || v2 < 0 || v3 < 0) continue;
                mesh.indices.push_back(static_cast<uint32_t>(v1));
                mesh.indices.push_back(static_cast<uint32_t>(v2));
                mesh.indices.push_back(static_cast<uint32_t>(v3));
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

void appendMesh(const MeshChunk &chunk, const Matrix3x4 &transform,
                RawMesh &out) {
    if (chunk.positions.empty() || chunk.indices.empty()) return;

    const uint32_t base = static_cast<uint32_t>(out.positions.size() / 3);
    for (size_t i = 0; i + 2 < chunk.positions.size(); i += 3) {
        float x = chunk.positions[i];
        float y = chunk.positions[i + 1];
        float z = chunk.positions[i + 2];
        transform.apply(x, y, z);
        out.positions.push_back(x);
        out.positions.push_back(y);
        out.positions.push_back(z);
    }
    for (uint32_t idx : chunk.indices) {
        out.indices.push_back(base + idx);
    }
}

void resolveObject(const std::map<std::string, std::string> &models,
                   const std::string &modelPath, int objectId,
                   const Matrix3x4 &transform, RawMesh &out,
                   std::vector<std::string> &stack) {
    const auto it = models.find(modelPath);
    if (it == models.end()) return;
    for (const auto &seen : stack) {
        if (seen == modelPath) return;
    }
    stack.push_back(modelPath);

    const auto objects = parseObjectsFromXml(it->second);
    const auto objIt = objects.find(objectId);
    if (objIt == objects.end()) {
        stack.pop_back();
        return;
    }

    const ObjectDef &obj = objIt->second;
    if (!obj.mesh.positions.empty()) {
        appendMesh(obj.mesh, transform, out);
    }
    for (size_t i = 0; i < obj.componentPaths.size(); ++i) {
        const Matrix3x4 next = transform.multiply(obj.componentTransforms[i]);
        resolveObject(models, obj.componentPaths[i], obj.componentObjectIds[i],
                      next, out, stack);
    }
    stack.pop_back();
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
    std::vector<std::string> stack;

    for (size_t i = 0; i < rootXml.size();) {
        const size_t lt = rootXml.find('<', i);
        if (lt == std::string::npos) break;
        const size_t gt = rootXml.find('>', lt);
        if (gt == std::string::npos) break;
        const std::string tag = rootXml.substr(lt, gt - lt + 1);
        if (tagIs(tag, "item")) {
            const int objectId = parseIntAttr(tag, "objectid");
            if (objectId < 0) {
                i = gt + 1;
                continue;
            }
            const Matrix3x4 transform = parseTransform(attrValue(tag, "transform"));
            resolveObject(models, rootPath, objectId, transform, outMesh, stack);
        }
        i = gt + 1;
    }

    if (outMesh.positions.empty() || outMesh.indices.empty()) {
        // Some exporters omit a build section — merge every mesh object we found.
        for (const auto &entry : models) {
            const auto objectsInFile = parseObjectsFromXml(entry.second);
            for (const auto &objEntry : objectsInFile) {
                appendMesh(objEntry.second.mesh, Matrix3x4::identity(), outMesh);
            }
        }
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
        outError = "Could not open this 3MF file.";
        return false;
    }

    std::map<std::string, ZipEntry> entries;
    if (!extractZip(zip, entries)) {
        outError = "This 3MF file does not contain a readable model.";
        return false;
    }

    return buildMeshFromArchive(entries, outMesh, outError);
}