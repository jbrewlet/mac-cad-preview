#include "cadmesh.h"
#include "read_3mf.h"

#include <STEPCAFControl_Reader.hxx>
#include <IGESCAFControl_Reader.hxx>
#include <RWStl.hxx>
#include <TDocStd_Document.hxx>
#include <TDF_LabelSequence.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <XCAFPrs.hxx>
#include <XCAFPrs_IndexedDataMapOfShapeStyle.hxx>
#include <XCAFPrs_Style.hxx>

#include <BRepMesh_IncrementalMesh.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <BRepBndLib.hxx>
#include <Bnd_Box.hxx>
#include <Poly_Triangulation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopTools_ShapeMapHasher.hxx>
#include <NCollection_DataMap.hxx>
#include <NCollection_Sequence.hxx>
#include <Interface_Static.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Message.hxx>
#include <Quantity_ColorRGBA.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>
#include <gp_Vec.hxx>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

namespace {

// The neutral grey used when a file carries no colour for a face.
constexpr float kDefaultColor[4] = {0.72f, 0.74f, 0.78f, 1.0f};

char *dupString(const std::string &s) {
    char *out = static_cast<char *>(std::malloc(s.size() + 1));
    if (out) std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

std::string lowerExtension(const std::string &path) {
    const size_t dot = path.find_last_of('.');
    if (dot == std::string::npos) return "";
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return ext;
}

CADMesh *makeError(const std::string &message) {
    CADMesh *mesh = static_cast<CADMesh *>(std::calloc(1, sizeof(CADMesh)));
    if (!mesh) return nullptr;
    mesh->error = dupString(message);
    return mesh;
}

using ColorKey = uint32_t;
using FaceColorMap = NCollection_DataMap<TopoDS_Shape, Quantity_ColorRGBA, TopTools_ShapeMapHasher>;

// Quantise to 8 bits per channel so nearly-identical colours share a material
// rather than producing hundreds of near-duplicate draw calls.
ColorKey packColor(float r, float g, float b, float a) {
    auto q = [](float v) -> uint32_t {
        return static_cast<uint32_t>(std::lround(std::min(std::max(v, 0.0f), 1.0f) * 255.0f));
    };
    return (q(r) << 24) | (q(g) << 16) | (q(b) << 8) | q(a);
}

void unpackColor(ColorKey key, float *rgba) {
    rgba[0] = ((key >> 24) & 0xFF) / 255.0f;
    rgba[1] = ((key >> 16) & 0xFF) / 255.0f;
    rgba[2] = ((key >> 8) & 0xFF) / 255.0f;
    rgba[3] = (key & 0xFF) / 255.0f;
}

// Reads a STEP or IGES file through OCCT's XCAF layer, which — unlike the
// plain readers — preserves the styled_item colour entities.
bool readWithColors(const std::string &path, const std::string &ext,
                    TopoDS_Shape &outShape, FaceColorMap &outColors,
                    std::string &outError) {
    // Constructing the document directly avoids needing a storage-format
    // plugin; we only ever read it in memory.
    Handle(TDocStd_Document) doc = new TDocStd_Document("BinXCAF");

    if (ext == "step" || ext == "stp" || ext == "p21") {
        STEPCAFControl_Reader reader;
        reader.SetColorMode(Standard_True);
        reader.SetNameMode(Standard_True);
        if (reader.ReadFile(path.c_str()) != IFSelect_RetDone) {
            outError = "Could not parse this STEP file.";
            return false;
        }
        if (!reader.Transfer(doc)) {
            outError = "STEP file parsed, but no geometry could be transferred.";
            return false;
        }
    } else {
        IGESCAFControl_Reader reader;
        reader.SetColorMode(Standard_True);
        reader.SetNameMode(Standard_True);
        if (reader.ReadFile(path.c_str()) != IFSelect_RetDone) {
            outError = "Could not parse this IGES file.";
            return false;
        }
        if (!reader.Transfer(doc)) {
            outError = "IGES file parsed, but no geometry could be transferred.";
            return false;
        }
    }

    Handle(XCAFDoc_ShapeTool) shapeTool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
    TDF_LabelSequence roots;
    shapeTool->GetFreeShapes(roots);
    if (roots.IsEmpty()) {
        outError = "File contained no shapes.";
        return false;
    }

    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);

    XCAFPrs_IndexedDataMapOfShapeStyle styles;
    for (TDF_LabelSequence::Iterator it(roots); it.More(); it.Next()) {
        const TDF_Label &label = it.Value();
        TopoDS_Shape shape = shapeTool->GetShape(label);
        if (shape.IsNull()) continue;
        builder.Add(compound, shape);
        XCAFPrs::CollectStyleSettings(label, TopLoc_Location(), styles);
    }

    // Styles can be attached at any level — a whole solid, or one face. Bind
    // the coarse ones first so that a face-specific colour overrides the
    // colour of the body it belongs to.
    for (int pass = 0; pass < 2; ++pass) {
        const bool wantFaces = (pass == 1);
        for (Standard_Integer i = 1; i <= styles.Extent(); ++i) {
            const TopoDS_Shape &shape = styles.FindKey(i);
            const XCAFPrs_Style &style = styles.FindFromIndex(i);
            if (!style.IsSetColorSurf()) continue;
            if ((shape.ShapeType() == TopAbs_FACE) != wantFaces) continue;

            for (TopExp_Explorer fe(shape, TopAbs_FACE); fe.More(); fe.Next()) {
                outColors.Bind(fe.Current(), style.GetColorSurfRGBA());
            }
        }
    }

    outShape = compound;
    if (outShape.IsNull()) {
        outError = "File parsed, but contained no geometry.";
        return false;
    }
    return true;
}

CADMesh *finalizeMesh(std::vector<float> &positions,
                      std::vector<float> &normals,
                      std::map<ColorKey, std::vector<uint32_t>> &buckets,
                      int faceCount,
                      double xMin, double yMin, double zMin,
                      double xMax, double yMax, double zMax) {
    if (buckets.empty()) return makeError("Nothing could be tessellated from this model.");

    for (size_t i = 0; i + 2 < normals.size(); i += 3) {
        const float len = std::sqrt(normals[i] * normals[i] +
                                    normals[i + 1] * normals[i + 1] +
                                    normals[i + 2] * normals[i + 2]);
        if (len > 1e-12f) {
            normals[i] /= len; normals[i + 1] /= len; normals[i + 2] /= len;
        } else {
            normals[i] = 0.0f; normals[i + 1] = 0.0f; normals[i + 2] = 1.0f;
        }
    }

    std::vector<uint32_t> indices;
    std::vector<CADMeshGroup> groups;
    groups.reserve(buckets.size());
    for (const auto &entry : buckets) {
        CADMeshGroup group;
        group.firstIndex = static_cast<uint32_t>(indices.size());
        group.indexCount = static_cast<uint32_t>(entry.second.size());
        unpackColor(entry.first, group.rgba);
        groups.push_back(group);
        indices.insert(indices.end(), entry.second.begin(), entry.second.end());
    }

    CADMesh *mesh = static_cast<CADMesh *>(std::calloc(1, sizeof(CADMesh)));
    if (!mesh) return nullptr;

    mesh->vertexCount   = static_cast<uint32_t>(positions.size() / 3);
    mesh->triangleCount = static_cast<uint32_t>(indices.size() / 3);
    mesh->groupCount    = static_cast<uint32_t>(groups.size());
    mesh->positions = static_cast<float *>(std::malloc(positions.size() * sizeof(float)));
    mesh->normals   = static_cast<float *>(std::malloc(normals.size() * sizeof(float)));
    mesh->indices   = static_cast<uint32_t *>(std::malloc(indices.size() * sizeof(uint32_t)));
    mesh->groups    = static_cast<CADMeshGroup *>(std::malloc(groups.size() * sizeof(CADMeshGroup)));
    if (!mesh->positions || !mesh->normals || !mesh->indices || !mesh->groups) {
        cadmesh_free(mesh);
        return makeError("Out of memory building mesh.");
    }
    std::memcpy(mesh->positions, positions.data(), positions.size() * sizeof(float));
    std::memcpy(mesh->normals,   normals.data(),   normals.size() * sizeof(float));
    std::memcpy(mesh->indices,   indices.data(),   indices.size() * sizeof(uint32_t));
    std::memcpy(mesh->groups,    groups.data(),    groups.size() * sizeof(CADMeshGroup));

    mesh->bboxMin[0] = static_cast<float>(xMin);
    mesh->bboxMin[1] = static_cast<float>(yMin);
    mesh->bboxMin[2] = static_cast<float>(zMin);
    mesh->bboxMax[0] = static_cast<float>(xMax);
    mesh->bboxMax[1] = static_cast<float>(yMax);
    mesh->bboxMax[2] = static_cast<float>(zMax);

    char info[512];
    std::snprintf(info, sizeof(info),
                  "%.1f × %.1f × %.1f\n%d faces · %u triangles · %u colours",
                  xMax - xMin, yMax - yMin, zMax - zMin,
                  faceCount, mesh->triangleCount, mesh->groupCount);
    mesh->info = dupString(info);

    return mesh;
}

void appendTriangulation(const Handle(Poly_Triangulation) &tri,
                         const gp_Trsf &trsf,
                         bool reversed,
                         ColorKey colorKey,
                         std::vector<float> &positions,
                         std::vector<float> &normals,
                         std::map<ColorKey, std::vector<uint32_t>> &buckets) {
    if (tri.IsNull()) return;

    const uint32_t base = static_cast<uint32_t>(positions.size() / 3);
    std::vector<uint32_t> &bucket = buckets[colorKey];

    for (int i = 1; i <= tri->NbNodes(); ++i) {
        gp_Pnt p = tri->Node(i);
        p.Transform(trsf);
        positions.push_back(static_cast<float>(p.X()));
        positions.push_back(static_cast<float>(p.Y()));
        positions.push_back(static_cast<float>(p.Z()));
        normals.insert(normals.end(), {0.0f, 0.0f, 0.0f});
    }

    for (int i = 1; i <= tri->NbTriangles(); ++i) {
        int a, b, c;
        tri->Triangle(i).Get(a, b, c);
        if (reversed) std::swap(b, c);

        const uint32_t ia = base + a - 1;
        const uint32_t ib = base + b - 1;
        const uint32_t ic = base + c - 1;
        bucket.push_back(ia);
        bucket.push_back(ib);
        bucket.push_back(ic);

        const gp_Vec v0(positions[ia * 3], positions[ia * 3 + 1], positions[ia * 3 + 2]);
        const gp_Vec v1(positions[ib * 3], positions[ib * 3 + 1], positions[ib * 3 + 2]);
        const gp_Vec v2(positions[ic * 3], positions[ic * 3 + 1], positions[ic * 3 + 2]);
        const gp_Vec n = (v1 - v0).Crossed(v2 - v0);
        for (uint32_t idx : {ia, ib, ic}) {
            normals[idx * 3]     += static_cast<float>(n.X());
            normals[idx * 3 + 1] += static_cast<float>(n.Y());
            normals[idx * 3 + 2] += static_cast<float>(n.Z());
        }
    }
}

CADMesh *loadFromTriangulations(const NCollection_Sequence<Handle(Poly_Triangulation)> &tris) {
    std::vector<float> positions;
    std::vector<float> normals;
    std::map<ColorKey, std::vector<uint32_t>> buckets;
    const ColorKey key = packColor(kDefaultColor[0], kDefaultColor[1],
                                   kDefaultColor[2], kDefaultColor[3]);
    gp_Trsf identity;
    int faceCount = 0;

    for (NCollection_Sequence<Handle(Poly_Triangulation)>::Iterator it(tris); it.More(); it.Next()) {
        appendTriangulation(it.Value(), identity, false, key, positions, normals, buckets);
        faceCount++;
    }

    if (positions.empty()) return makeError("File parsed, but contained no geometry.");

    double xMin = positions[0], yMin = positions[1], zMin = positions[2];
    double xMax = xMin, yMax = yMin, zMax = zMin;
    for (size_t i = 0; i + 2 < positions.size(); i += 3) {
        xMin = std::min(xMin, static_cast<double>(positions[i]));
        yMin = std::min(yMin, static_cast<double>(positions[i + 1]));
        zMin = std::min(zMin, static_cast<double>(positions[i + 2]));
        xMax = std::max(xMax, static_cast<double>(positions[i]));
        yMax = std::max(yMax, static_cast<double>(positions[i + 1]));
        zMax = std::max(zMax, static_cast<double>(positions[i + 2]));
    }

    return finalizeMesh(positions, normals, buckets, faceCount,
                        xMin, yMin, zMin, xMax, yMax, zMax);
}

CADMesh *loadFromRawMesh(const RawMesh &raw) {
    std::vector<float> positions = raw.positions;
    std::vector<float> normals(positions.size(), 0.0f);
    std::map<ColorKey, std::vector<uint32_t>> buckets;
    const ColorKey key = packColor(kDefaultColor[0], kDefaultColor[1],
                                   kDefaultColor[2], kDefaultColor[3]);
    std::vector<uint32_t> &bucket = buckets[key];
    bucket = raw.indices;

    for (size_t i = 0; i + 2 < raw.indices.size(); i += 3) {
        const uint32_t ia = raw.indices[i];
        const uint32_t ib = raw.indices[i + 1];
        const uint32_t ic = raw.indices[i + 2];
        const gp_Vec v0(positions[ia * 3], positions[ia * 3 + 1], positions[ia * 3 + 2]);
        const gp_Vec v1(positions[ib * 3], positions[ib * 3 + 1], positions[ib * 3 + 2]);
        const gp_Vec v2(positions[ic * 3], positions[ic * 3 + 1], positions[ic * 3 + 2]);
        const gp_Vec n = (v1 - v0).Crossed(v2 - v0);
        for (uint32_t idx : {ia, ib, ic}) {
            normals[idx * 3]     += static_cast<float>(n.X());
            normals[idx * 3 + 1] += static_cast<float>(n.Y());
            normals[idx * 3 + 2] += static_cast<float>(n.Z());
        }
    }

    double xMin = positions[0], yMin = positions[1], zMin = positions[2];
    double xMax = xMin, yMax = yMin, zMax = zMin;
    for (size_t i = 0; i + 2 < positions.size(); i += 3) {
        xMin = std::min(xMin, static_cast<double>(positions[i]));
        yMin = std::min(yMin, static_cast<double>(positions[i + 1]));
        zMin = std::min(zMin, static_cast<double>(positions[i + 2]));
        xMax = std::max(xMax, static_cast<double>(positions[i]));
        yMax = std::max(yMax, static_cast<double>(positions[i + 1]));
        zMax = std::max(zMax, static_cast<double>(positions[i + 2]));
    }

    return finalizeMesh(positions, normals, buckets, 1,
                        xMin, yMin, zMin, xMax, yMax, zMax);
}

} // namespace

extern "C" CADMesh *cadmesh_load(const char *path, double deflection) {
    if (!path) return makeError("No file path given.");

    // OCCT is chatty on stdout by default; inside an app extension that is
    // just noise.
    Message::DefaultMessenger()->ChangePrinters().Clear();

    const std::string filePath(path);
    const std::string ext = lowerExtension(filePath);

    TopoDS_Shape shape;
    FaceColorMap faceColors;
    std::string error;

    if (ext == "step" || ext == "stp" || ext == "p21" || ext == "iges" || ext == "igs") {
        if (!readWithColors(filePath, ext, shape, faceColors, error)) return makeError(error);
    } else if (ext == "stl") {
        // STL is already triangulated — read the mesh directly instead of
        // forcing it through the B-rep tessellator, which fails on some files.
        NCollection_Sequence<Handle(Poly_Triangulation)> tris;
        RWStl::ReadFile(filePath.c_str(), M_PI / 2.0, tris);
        if (tris.IsEmpty()) {
            Handle(Poly_Triangulation) tri = RWStl::ReadFile(filePath.c_str());
            if (tri.IsNull()) return makeError("Could not parse this STL file.");
            tris.Append(tri);
        }
        return loadFromTriangulations(tris);
    } else if (ext == "3mf") {
        RawMesh raw;
        if (!read3mf(filePath, raw, error)) return makeError(error);
        return loadFromRawMesh(raw);
    } else {
        return makeError("Unsupported file type: ." + ext);
    }

    if (shape.IsNull()) return makeError("File parsed, but contained no geometry.");

    Bnd_Box box;
    BRepBndLib::Add(shape, box);
    if (box.IsVoid()) return makeError("Model has no measurable extent.");

    double xMin, yMin, zMin, xMax, yMax, zMax;
    box.Get(xMin, yMin, zMin, xMax, yMax, zMax);
    const double diagonal = std::sqrt((xMax - xMin) * (xMax - xMin) +
                                      (yMax - yMin) * (yMax - yMin) +
                                      (zMax - zMin) * (zMax - zMin));

    // Deflection is the max distance between the real surface and our
    // triangles. Tying it to model size keeps quality consistent whether the
    // part is a 2 mm screw or a 4 m chassis.
    if (deflection <= 0.0) deflection = std::max(diagonal * 0.001, 1e-6);

    BRepMesh_IncrementalMesh mesher(shape, deflection, Standard_False, 0.5, Standard_True);
    mesher.Perform();

    std::vector<float> positions;
    std::vector<float> normals;
    // Triangles bucketed by colour, so each bucket becomes one draw call.
    std::map<ColorKey, std::vector<uint32_t>> buckets;

    int faceCount = 0;
    for (TopExp_Explorer exp(shape, TopAbs_FACE); exp.More(); exp.Next()) {
        const TopoDS_Face face = TopoDS::Face(exp.Current());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (tri.IsNull()) continue;
        faceCount++;

        ColorKey key;
        if (faceColors.IsBound(face)) {
            const Quantity_ColorRGBA &c = faceColors.Find(face);
            const Quantity_Color &rgb = c.GetRGB();
            key = packColor(static_cast<float>(rgb.Red()),
                            static_cast<float>(rgb.Green()),
                            static_cast<float>(rgb.Blue()),
                            c.Alpha());
        } else {
            key = packColor(kDefaultColor[0], kDefaultColor[1],
                            kDefaultColor[2], kDefaultColor[3]);
        }
        std::vector<uint32_t> &bucket = buckets[key];

        const gp_Trsf trsf = loc.Transformation();
        const uint32_t base = static_cast<uint32_t>(positions.size() / 3);
        const bool reversed = (face.Orientation() == TopAbs_REVERSED);

        for (int i = 1; i <= tri->NbNodes(); ++i) {
            gp_Pnt p = tri->Node(i);
            p.Transform(trsf);
            positions.push_back(static_cast<float>(p.X()));
            positions.push_back(static_cast<float>(p.Y()));
            positions.push_back(static_cast<float>(p.Z()));
            normals.insert(normals.end(), {0.0f, 0.0f, 0.0f});
        }

        for (int i = 1; i <= tri->NbTriangles(); ++i) {
            int a, b, c;
            tri->Triangle(i).Get(a, b, c);
            // A reversed face means the surface normal points the other way,
            // so flip the winding to keep the outside facing out.
            if (reversed) std::swap(b, c);

            const uint32_t ia = base + a - 1;
            const uint32_t ib = base + b - 1;
            const uint32_t ic = base + c - 1;
            bucket.push_back(ia);
            bucket.push_back(ib);
            bucket.push_back(ic);

            // Accumulate area-weighted face normals onto each vertex; we
            // normalise in a second pass to get smooth shading.
            const gp_Vec v0(positions[ia * 3], positions[ia * 3 + 1], positions[ia * 3 + 2]);
            const gp_Vec v1(positions[ib * 3], positions[ib * 3 + 1], positions[ib * 3 + 2]);
            const gp_Vec v2(positions[ic * 3], positions[ic * 3 + 1], positions[ic * 3 + 2]);
            const gp_Vec n = (v1 - v0).Crossed(v2 - v0);
            for (uint32_t idx : {ia, ib, ic}) {
                normals[idx * 3]     += static_cast<float>(n.X());
                normals[idx * 3 + 1] += static_cast<float>(n.Y());
                normals[idx * 3 + 2] += static_cast<float>(n.Z());
            }
        }
    }

    return finalizeMesh(positions, normals, buckets, faceCount,
                        xMin, yMin, zMin, xMax, yMax, zMax);
}

extern "C" void cadmesh_free(CADMesh *mesh) {
    if (!mesh) return;
    std::free(mesh->positions);
    std::free(mesh->normals);
    std::free(mesh->indices);
    std::free(mesh->groups);
    std::free(mesh->info);
    std::free(mesh->error);
    std::free(mesh);
}
