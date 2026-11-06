#include "read_dxf.h"

#include <xlocale.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <new>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace {

// Limits that keep an enormous or hostile file from exhausting the Quick Look
// extension's memory, or from stalling it in block expansion.
constexpr long long kMaxFileBytes = 256LL * 1024 * 1024;
constexpr size_t kMaxSegments = 1500000;
constexpr size_t kMaxTriangles = 1500000;
constexpr int kMaxBlockDepth = 16;
constexpr long long kMaxBlockExpansions = 2000000;
constexpr long long kMaxArrayCells = 100000;
constexpr int kCircleSegments = 72;
constexpr int kMaxSplineSamples = 1024;
constexpr int kMaxSplineDegree = 10;
constexpr double kPi = 3.14159265358979323846;

std::string upper(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return s;
}

// DXF numbers always use '.', whatever locale the host process runs in.
locale_t cLocale() {
    static locale_t locale = newlocale(LC_ALL_MASK, "C", nullptr);
    return locale;
}

double toReal(const std::string &s, double fallback) {
    const char *begin = s.c_str();
    char *end = nullptr;
    const double v = strtod_l(begin, &end, cLocale());
    if (end == begin || !std::isfinite(v)) return fallback;
    return v;
}

long toInteger(const std::string &s, long fallback) {
    const char *begin = s.c_str();
    char *end = nullptr;
    const long v = std::strtol(begin, &end, 10);
    return end == begin ? fallback : v;
}

// MARK: - Group reader

struct Group {
    int code = 0;
    std::string value;
};

// Streams (group code, value) line pairs, with one group of push-back.
class GroupReader {
public:
    explicit GroupReader(std::FILE *file) : file_(file) {}

    bool next(Group &out) {
        if (hasPending_) {
            out = std::move(pending_);
            hasPending_ = false;
            return true;
        }
        std::string codeLine;
        while (true) {
            if (!readLine(codeLine)) return false;
            if (!parseCode(codeLine, out.code)) {
                malformed_ = true;
                return false;
            }
            if (!readLine(out.value)) {
                malformed_ = true;
                return false;
            }
            if (out.code != 999) return true;   // 999 is a comment
        }
    }

    void pushBack(Group group) {
        pending_ = std::move(group);
        hasPending_ = true;
    }

    bool malformed() const { return malformed_; }
    long line() const { return line_; }

private:
    bool readLine(std::string &line) {
        line.clear();
        bool any = false;
        while (true) {
            if (pos_ == len_) {
                len_ = std::fread(buffer_, 1, sizeof(buffer_), file_);
                pos_ = 0;
                if (len_ == 0) break;
            }
            const char *start = buffer_ + pos_;
            const void *newline = std::memchr(start, '\n', len_ - pos_);
            const size_t take = newline
                ? static_cast<size_t>(static_cast<const char *>(newline) - start)
                : len_ - pos_;
            line.append(start, take);
            any = true;
            pos_ += take;
            if (newline) {
                ++pos_;
                break;
            }
        }
        if (!any) return false;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line_ == 0 && line.compare(0, 3, "\xEF\xBB\xBF") == 0) line.erase(0, 3);
        ++line_;
        return true;
    }

    static bool parseCode(const std::string &line, int &code) {
        size_t i = 0;
        while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        const char *begin = line.c_str() + i;
        char *end = nullptr;
        const long v = std::strtol(begin, &end, 10);
        if (end == begin) return false;
        while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
        if (*end || v < 0 || v > 1071) return false;
        code = static_cast<int>(v);
        return true;
    }

    std::FILE *file_;
    char buffer_[1 << 16];
    size_t pos_ = 0;
    size_t len_ = 0;
    long line_ = 0;
    Group pending_;
    bool hasPending_ = false;
    bool malformed_ = false;
};

// MARK: - Entities

struct Entity {
    std::string type;
    std::vector<Group> groups;
    std::vector<Entity> children;   // the VERTEX records of a POLYLINE

    const Group *find(int code) const {
        for (const Group &g : groups) {
            if (g.code == code) return &g;
        }
        return nullptr;
    }
    double real(int code, double fallback = 0.0) const {
        const Group *g = find(code);
        return g ? toReal(g->value, fallback) : fallback;
    }
    long integer(int code, long fallback = 0) const {
        const Group *g = find(code);
        return g ? toInteger(g->value, fallback) : fallback;
    }
    std::string text(int code, const char *fallback = "") const {
        const Group *g = find(code);
        return g ? g->value : fallback;
    }
};

// Handles, owner links, subclass markers and extended data are never needed
// for drawing, and are most of what a large file holds.
bool keepGroup(int code) {
    return code < 1000 && code != 5 && code != 100 && code != 102 &&
           code != 330 && code != 360;
}

void readEntityBody(GroupReader &reader, Entity &entity) {
    Group g;
    while (reader.next(g)) {
        if (g.code == 0) {
            reader.pushBack(std::move(g));
            return;
        }
        if (keepGroup(g.code)) entity.groups.push_back(std::move(g));
    }
}

// Reads the next entity of an ENTITIES or BLOCK list, gathering the records a
// POLYLINE or attributed INSERT owns up to their SEQEND. Returns false, with
// the terminating group pushed back, at ENDBLK, ENDSEC or EOF.
bool readEntity(GroupReader &reader, Entity &out) {
    Group g;
    while (true) {
        if (!reader.next(g)) return false;
        if (g.code != 0) continue;
        if (g.value == "ENDBLK" || g.value == "ENDSEC" || g.value == "EOF") {
            reader.pushBack(std::move(g));
            return false;
        }
        break;
    }
    out = Entity();
    out.type = g.value;
    readEntityBody(reader, out);

    const bool ownsRecords = (out.type == "POLYLINE") ||
                             (out.type == "INSERT" && out.integer(66) == 1);
    if (!ownsRecords) return true;

    while (reader.next(g)) {
        if (g.code != 0) continue;
        if (g.value == "SEQEND") {
            Entity end;
            readEntityBody(reader, end);
            break;
        }
        if (g.value != "VERTEX" && g.value != "ATTRIB") {
            reader.pushBack(std::move(g));      // SEQEND missing; carry on
            break;
        }
        Entity child;
        child.type = g.value;
        readEntityBody(reader, child);
        if (child.type == "VERTEX") out.children.push_back(std::move(child));
    }
    return true;
}

void skipSection(GroupReader &reader) {
    Group g;
    while (reader.next(g)) {
        if (g.code == 0 && (g.value == "ENDSEC" || g.value == "EOF")) {
            if (g.value == "EOF") reader.pushBack(std::move(g));
            return;
        }
    }
}

// MARK: - Geometry

struct Vec3 {
    double x = 0, y = 0, z = 0;
};

Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 operator*(Vec3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
double length(Vec3 a) { return std::sqrt(a.x * a.x + a.y * a.y + a.z * a.z); }
bool finite(Vec3 a) { return std::isfinite(a.x) && std::isfinite(a.y) && std::isfinite(a.z); }

// Affine transform, rows of a 3x4 matrix. (a * b).apply(p) == a.apply(b.apply(p)).
struct Xform {
    double m[3][4] = {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}};

    Vec3 apply(Vec3 p) const {
        return {m[0][0] * p.x + m[0][1] * p.y + m[0][2] * p.z + m[0][3],
                m[1][0] * p.x + m[1][1] * p.y + m[1][2] * p.z + m[1][3],
                m[2][0] * p.x + m[2][1] * p.y + m[2][2] * p.z + m[2][3]};
    }

    Xform operator*(const Xform &o) const {
        Xform r;
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 4; ++j) {
                r.m[i][j] = m[i][0] * o.m[0][j] + m[i][1] * o.m[1][j] + m[i][2] * o.m[2][j] +
                            (j == 3 ? m[i][3] : 0.0);
            }
        }
        return r;
    }

    static Xform translation(Vec3 t) {
        Xform r;
        r.m[0][3] = t.x; r.m[1][3] = t.y; r.m[2][3] = t.z;
        return r;
    }
    static Xform scale(Vec3 s) {
        Xform r;
        r.m[0][0] = s.x; r.m[1][1] = s.y; r.m[2][2] = s.z;
        return r;
    }
    static Xform rotationZ(double radians) {
        Xform r;
        const double c = std::cos(radians), s = std::sin(radians);
        r.m[0][0] = c; r.m[0][1] = -s;
        r.m[1][0] = s; r.m[1][1] = c;
        return r;
    }
};

// The DXF "arbitrary axis algorithm": the object coordinate system that 2D
// entities (arcs, circles, lightweight polylines, inserts) are stored in.
Xform objectCoordinates(Vec3 extrusion) {
    const double len = length(extrusion);
    if (!(len > 1e-12)) return Xform();
    const Vec3 n = extrusion * (1.0 / len);
    if (std::abs(n.x) < 1e-12 && std::abs(n.y) < 1e-12 && n.z > 0) return Xform();

    const double limit = 1.0 / 64.0;
    Vec3 ax = (std::abs(n.x) < limit && std::abs(n.y) < limit)
        ? cross({0, 1, 0}, n)
        : cross({0, 0, 1}, n);
    ax = ax * (1.0 / length(ax));
    Vec3 ay = cross(n, ax);
    ay = ay * (1.0 / length(ay));

    Xform r;
    r.m[0][0] = ax.x; r.m[0][1] = ay.x; r.m[0][2] = n.x;
    r.m[1][0] = ax.y; r.m[1][1] = ay.y; r.m[1][2] = n.y;
    r.m[2][0] = ax.z; r.m[2][1] = ay.z; r.m[2][2] = n.z;
    return r;
}

int arcSteps(double sweep) {
    const double fraction = std::abs(sweep) / (2.0 * kPi);
    return std::max(2, static_cast<int>(std::ceil(kCircleSegments * std::min(fraction, 1.0))));
}

// Sweep in (0, 2π], counter-clockwise from start to end.
double ccwSweep(double start, double end) {
    double sweep = std::fmod(end - start, 2.0 * kPi);
    if (sweep <= 1e-12) sweep += 2.0 * kPi;
    return sweep;
}

struct Block {
    Vec3 base;
    std::vector<Entity> entities;
};

struct PolyVertex {
    double x = 0, y = 0, bulge = 0;
};

class Emitter {
public:
    Emitter(const std::map<std::string, Block> &blocks,
            const std::set<std::string> &hiddenLayers,
            DxfDrawing &out)
        : blocks_(blocks), hiddenLayers_(hiddenLayers), out_(out) {}

    void emit(const Entity &e, const Xform &xf, const std::string &parentLayer, int depth) {
        if (stopped_) return;

        // Entities on layer 0 inside a block take the layer of the insert.
        std::string layer = upper(e.text(8, "0"));
        if (depth > 0 && layer == "0") layer = parentLayer;
        if (hiddenLayers_.count(layer)) return;

        const size_t segmentsBefore = out_.segments.size();
        const size_t facesBefore = out_.faces.indices.size();
        const std::string &t = e.type;

        if (t == "LINE") {
            segment(xf, point(e, 10), point(e, 11));
        } else if (t == "CIRCLE") {
            arc(xf * extrusion(e), point(e, 10), e.real(40), 0.0, 2.0 * kPi);
        } else if (t == "ARC") {
            const double start = radians(e.real(50));
            arc(xf * extrusion(e), point(e, 10), e.real(40),
                start, ccwSweep(start, radians(e.real(51))));
        } else if (t == "ELLIPSE") {
            ellipse(xf, e);
        } else if (t == "LWPOLYLINE") {
            lightweightPolyline(xf, e);
        } else if (t == "POLYLINE") {
            polyline(xf, e);
        } else if (t == "SPLINE") {
            spline(xf, e);
        } else if (t == "3DFACE") {
            quad(xf, point(e, 10), point(e, 11), point(e, 12), point(e, 13));
        } else if (t == "SOLID" || t == "TRACE") {
            // Corners 3 and 4 are stored swapped relative to the outline.
            quad(xf * extrusion(e), point(e, 10), point(e, 11), point(e, 13), point(e, 12));
        } else if (t == "INSERT") {
            insert(xf, e, layer, depth);
        } else if (t == "DIMENSION") {
            // A dimension's lines and arrows live in an anonymous block, already
            // placed in the dimension's own coordinates.
            expandBlock(e.text(2), xf, layer, depth);
        } else if (t != "POINT" && t != "VIEWPORT" && t != "ATTDEF" && t != "SEQEND") {
            out_.skippedTypes.insert(t);
        }

        const bool drew = out_.segments.size() != segmentsBefore ||
                          out_.faces.indices.size() != facesBefore;
        if (drew && depth == 0) ++out_.entityCount;
    }

private:
    static double radians(double degrees) { return degrees * kPi / 180.0; }

    // A hard limit was reached: nothing more is drawn, and the preview is
    // marked partial. (A clamped insert array is partial too, but drawing
    // carries on.)
    void stop() {
        stopped_ = true;
        out_.truncated = true;
    }

    static Vec3 point(const Entity &e, int code) {
        return {e.real(code), e.real(code + 10), e.real(code + 20)};
    }

    static Xform extrusion(const Entity &e) {
        return objectCoordinates({e.real(210, 0.0), e.real(220, 0.0), e.real(230, 1.0)});
    }

    void segment(const Xform &xf, Vec3 a, Vec3 b) {
        if (stopped_) return;
        if (out_.segments.size() / 6 >= kMaxSegments) {
            stop();
            return;
        }
        const Vec3 p = xf.apply(a), q = xf.apply(b);
        if (!finite(p) || !finite(q)) return;
        out_.segments.insert(out_.segments.end(),
                             {static_cast<float>(p.x), static_cast<float>(p.y), static_cast<float>(p.z),
                              static_cast<float>(q.x), static_cast<float>(q.y), static_cast<float>(q.z)});
    }

    void triangle(const Xform &xf, Vec3 a, Vec3 b, Vec3 c) {
        if (stopped_) return;
        if (out_.faces.indices.size() / 3 >= kMaxTriangles) {
            stop();
            return;
        }
        const Vec3 p[3] = {xf.apply(a), xf.apply(b), xf.apply(c)};
        if (!finite(p[0]) || !finite(p[1]) || !finite(p[2])) return;
        std::vector<float> &positions = out_.faces.positions;
        const uint32_t base = static_cast<uint32_t>(positions.size() / 3);
        for (const Vec3 &v : p) {
            positions.insert(positions.end(),
                             {static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)});
        }
        out_.faces.indices.insert(out_.faces.indices.end(), {base, base + 1, base + 2});
    }

    void quad(const Xform &xf, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
        triangle(xf, a, b, c);
        if (length(d - c) > 1e-12) triangle(xf, a, c, d);
    }

    void arc(const Xform &xf, Vec3 centre, double radius, double start, double sweep) {
        if (!(radius > 0) || !std::isfinite(radius) || !std::isfinite(start) || !std::isfinite(sweep)) return;
        const int steps = arcSteps(sweep);
        Vec3 previous{centre.x + radius * std::cos(start), centre.y + radius * std::sin(start), centre.z};
        for (int i = 1; i <= steps; ++i) {
            const double a = start + sweep * i / steps;
            const Vec3 next{centre.x + radius * std::cos(a), centre.y + radius * std::sin(a), centre.z};
            segment(xf, previous, next);
            previous = next;
        }
    }

    void ellipse(const Xform &xf, const Entity &e) {
        const Vec3 centre = point(e, 10);
        const Vec3 major = point(e, 11);
        const double ratio = e.real(40, 1.0);
        Vec3 normal{e.real(210, 0.0), e.real(220, 0.0), e.real(230, 1.0)};
        const double normalLength = length(normal);
        if (!(normalLength > 1e-12) || !(ratio > 0) || !(length(major) > 0)) return;
        normal = normal * (1.0 / normalLength);
        const Vec3 minor = cross(normal, major) * ratio;

        const double start = e.real(41, 0.0);
        const double sweep = ccwSweep(start, e.real(42, 2.0 * kPi));
        const int steps = arcSteps(sweep);
        auto at = [&](double t) { return centre + major * std::cos(t) + minor * std::sin(t); };
        Vec3 previous = at(start);
        for (int i = 1; i <= steps; ++i) {
            const Vec3 next = at(start + sweep * i / steps);
            segment(xf, previous, next);
            previous = next;
        }
    }

    // A bulge is tan(θ/4) of the arc from this vertex to the next; positive
    // runs counter-clockwise.
    void bulgeSegment(const Xform &xf, PolyVertex a, PolyVertex b, double z) {
        const Vec3 p{a.x, a.y, z}, q{b.x, b.y, z};
        const double dx = b.x - a.x, dy = b.y - a.y;
        const double chord = std::sqrt(dx * dx + dy * dy);
        if (std::abs(a.bulge) < 1e-9 || chord < 1e-12 || !std::isfinite(a.bulge)) {
            segment(xf, p, q);
            return;
        }
        const double theta = 4.0 * std::atan(a.bulge);
        // A bulge near ±infinity is a full turn through a point: its radius
        // is unbounded, and it would wreck the framing of the whole drawing.
        if (std::abs(std::sin(theta / 2.0)) < 1e-9) {
            segment(xf, p, q);
            return;
        }
        const double offset = (chord / 2.0) / std::tan(theta / 2.0);
        const Vec3 centre{(a.x + b.x) / 2.0 - dy / chord * offset,
                          (a.y + b.y) / 2.0 + dx / chord * offset, z};
        const double radius = chord / (2.0 * std::abs(std::sin(theta / 2.0)));
        const double start = std::atan2(a.y - centre.y, a.x - centre.x);
        const int steps = arcSteps(theta);
        Vec3 previous = p;
        for (int i = 1; i < steps; ++i) {
            const double angle = start + theta * i / steps;
            const Vec3 next{centre.x + radius * std::cos(angle), centre.y + radius * std::sin(angle), z};
            segment(xf, previous, next);
            previous = next;
        }
        segment(xf, previous, q);
    }

    void bulgePolyline(const Xform &xf, const std::vector<PolyVertex> &vertices, double z, bool closed) {
        const size_t n = vertices.size();
        if (n < 2) return;
        const size_t spans = closed ? n : n - 1;
        for (size_t i = 0; i < spans; ++i) {
            bulgeSegment(xf, vertices[i], vertices[(i + 1) % n], z);
        }
    }

    void lightweightPolyline(const Xform &xf, const Entity &e) {
        std::vector<PolyVertex> vertices;
        for (const Group &g : e.groups) {
            if (g.code == 10) {
                vertices.push_back({toReal(g.value, 0.0), 0.0, 0.0});
            } else if (!vertices.empty() && g.code == 20) {
                vertices.back().y = toReal(g.value, 0.0);
            } else if (!vertices.empty() && g.code == 42) {
                vertices.back().bulge = toReal(g.value, 0.0);
            }
        }
        bulgePolyline(xf * extrusion(e), vertices, e.real(38), (e.integer(70) & 1) != 0);
    }

    void polyline(const Xform &xf, const Entity &e) {
        const long flags = e.integer(70);
        if (flags & 64) {
            polyfaceMesh(xf, e);
        } else if (flags & 16) {
            polygonMesh(xf, e, flags);
        } else if (flags & 8) {
            std::vector<Vec3> points;
            for (const Entity &v : e.children) {
                if (!(v.integer(70) & 16)) points.push_back(point(v, 10));   // skip spline frame
            }
            for (size_t i = 0; i + 1 < points.size(); ++i) segment(xf, points[i], points[i + 1]);
            if ((flags & 1) && points.size() > 2) segment(xf, points.back(), points.front());
        } else {
            std::vector<PolyVertex> vertices;
            for (const Entity &v : e.children) {
                if (v.integer(70) & 16) continue;
                vertices.push_back({v.real(10), v.real(20), v.real(42)});
            }
            bulgePolyline(xf * extrusion(e), vertices, e.real(30), (flags & 1) != 0);
        }
    }

    void polyfaceMesh(const Xform &xf, const Entity &e) {
        std::vector<Vec3> vertices;
        for (const Entity &v : e.children) {
            const long flags = v.integer(70);
            if (flags & 64) {
                vertices.push_back(point(v, 10));
            } else if (flags & 128) {
                long corners[4];
                int count = 0;
                for (int code = 71; code <= 74; ++code) {
                    const long index = std::labs(v.integer(code));
                    if (index >= 1 && static_cast<size_t>(index) <= vertices.size()) {
                        corners[count++] = index - 1;
                    }
                }
                if (count >= 3) {
                    triangle(xf, vertices[corners[0]], vertices[corners[1]], vertices[corners[2]]);
                }
                if (count == 4) {
                    triangle(xf, vertices[corners[0]], vertices[corners[2]], vertices[corners[3]]);
                }
            }
        }
    }

    void polygonMesh(const Xform &xf, const Entity &e, long flags) {
        const long rows = e.integer(71), cols = e.integer(72);
        if (rows < 2 || cols < 2 || rows > 1000000 || cols > 1000000) return;
        if (static_cast<unsigned long long>(rows) * static_cast<unsigned long long>(cols) >
            e.children.size()) return;
        auto at = [&](long r, long c) { return point(e.children[r * cols + c], 10); };
        const long rowSpans = (flags & 1) ? rows : rows - 1;
        const long colSpans = (flags & 32) ? cols : cols - 1;
        for (long r = 0; r < rowSpans && !stopped_; ++r) {
            for (long c = 0; c < colSpans; ++c) {
                const long r1 = (r + 1) % rows, c1 = (c + 1) % cols;
                quad(xf, at(r, c), at(r1, c), at(r1, c1), at(r, c1));
            }
        }
    }

    void spline(const Xform &xf, const Entity &e) {
        std::vector<double> knots, weights;
        std::vector<Vec3> control, fit;
        for (const Group &g : e.groups) {
            switch (g.code) {
            case 40: knots.push_back(toReal(g.value, 0.0)); break;
            case 41: weights.push_back(toReal(g.value, 1.0)); break;
            case 10: control.push_back({toReal(g.value, 0.0), 0, 0}); break;
            case 20: if (!control.empty()) control.back().y = toReal(g.value, 0.0); break;
            case 30: if (!control.empty()) control.back().z = toReal(g.value, 0.0); break;
            case 11: fit.push_back({toReal(g.value, 0.0), 0, 0}); break;
            case 21: if (!fit.empty()) fit.back().y = toReal(g.value, 0.0); break;
            case 31: if (!fit.empty()) fit.back().z = toReal(g.value, 0.0); break;
            default: break;
            }
        }

        const long degree = e.integer(71, 3);
        const size_t n = control.size();
        const bool evaluable = degree >= 1 && degree <= kMaxSplineDegree &&
                               n > static_cast<size_t>(degree) &&
                               knots.size() == n + degree + 1 &&
                               std::is_sorted(knots.begin(), knots.end()) &&
                               knots[n] > knots[degree];
        if (!evaluable) {
            // Without a usable knot vector, the fit points (or failing that
            // the control polygon) are the best available outline.
            const std::vector<Vec3> &outline = fit.size() >= 2 ? fit : control;
            for (size_t i = 0; i + 1 < outline.size(); ++i) segment(xf, outline[i], outline[i + 1]);
            return;
        }
        if (weights.size() != n) weights.assign(n, 1.0);

        const int p = static_cast<int>(degree);
        const double t0 = knots[p], t1 = knots[n];
        const int samples = static_cast<int>(std::min<size_t>(std::max<size_t>(n * 8, 32), kMaxSplineSamples));

        // De Boor's algorithm in homogeneous coordinates, so rational splines
        // (circles and conics saved as NURBS) come out exact.
        struct H { double x, y, z, w; };
        std::vector<H> d(p + 1);
        auto evaluate = [&](double t) -> Vec3 {
            size_t k = static_cast<size_t>(p);
            while (k + 1 < n && knots[k + 1] <= t) ++k;
            for (int j = 0; j <= p; ++j) {
                const Vec3 &c = control[k - p + j];
                const double w = weights[k - p + j];
                d[j] = {c.x * w, c.y * w, c.z * w, w};
            }
            for (int r = 1; r <= p; ++r) {
                for (int j = p; j >= r; --j) {
                    const size_t i = k - p + j;
                    const double denom = knots[i + p - r + 1] - knots[i];
                    const double alpha = denom > 0 ? (t - knots[i]) / denom : 0.0;
                    d[j] = {(1 - alpha) * d[j - 1].x + alpha * d[j].x,
                            (1 - alpha) * d[j - 1].y + alpha * d[j].y,
                            (1 - alpha) * d[j - 1].z + alpha * d[j].z,
                            (1 - alpha) * d[j - 1].w + alpha * d[j].w};
                }
            }
            const H &h = d[p];
            if (std::abs(h.w) < 1e-300) return {NAN, NAN, NAN};
            return {h.x / h.w, h.y / h.w, h.z / h.w};
        };

        Vec3 previous = evaluate(t0);
        for (int i = 1; i <= samples && !stopped_; ++i) {
            const Vec3 next = evaluate(t0 + (t1 - t0) * i / samples);
            segment(xf, previous, next);
            previous = next;
        }
    }

    void insert(const Xform &xf, const Entity &e, const std::string &layer, int depth) {
        const auto block = blocks_.find(upper(e.text(2)));
        if (block == blocks_.end()) return;

        long cols = std::max(1L, e.integer(70, 1));
        long rows = std::max(1L, e.integer(71, 1));
        if (static_cast<long long>(cols) * rows > kMaxArrayCells) {
            out_.truncated = true;
            cols = rows = 1;
        }
        const double rotation = radians(e.real(50));
        const Vec3 at = point(e, 10);
        const double colSpacing = e.real(44), rowSpacing = e.real(45);
        const Xform placed = xf * extrusion(e);
        const Xform local = Xform::rotationZ(rotation) *
                            Xform::scale({e.real(41, 1.0), e.real(42, 1.0), e.real(43, 1.0)}) *
                            Xform::translation(block->second.base * -1.0);
        const Xform turn = Xform::rotationZ(rotation);

        for (long r = 0; r < rows; ++r) {
            for (long c = 0; c < cols; ++c) {
                const Vec3 cell = at + turn.apply({c * colSpacing, r * rowSpacing, 0.0});
                expand(block->first, block->second, placed * Xform::translation(cell) * local,
                       layer, depth);
                if (stopped_) return;
            }
        }
    }

    void expandBlock(const std::string &name, const Xform &xf, const std::string &layer, int depth) {
        const auto block = blocks_.find(upper(name));
        if (block == blocks_.end()) return;
        expand(block->first, block->second, xf, layer, depth);
    }

    void expand(const std::string &name, const Block &block, const Xform &xf,
                const std::string &layer, int depth) {
        if (depth + 1 > kMaxBlockDepth) return;
        // A block that (directly or not) inserts itself would never finish.
        if (std::find(stack_.begin(), stack_.end(), name) != stack_.end()) return;
        expansions_ += static_cast<long long>(block.entities.size());
        if (expansions_ > kMaxBlockExpansions) {
            stop();
            return;
        }
        stack_.push_back(name);
        for (const Entity &child : block.entities) {
            emit(child, xf, layer, depth + 1);
            if (stopped_) break;
        }
        stack_.pop_back();
    }

    const std::map<std::string, Block> &blocks_;
    const std::set<std::string> &hiddenLayers_;
    DxfDrawing &out_;
    std::vector<std::string> stack_;
    long long expansions_ = 0;
    bool stopped_ = false;
};

// MARK: - Sections

const char *versionName(const std::string &acadver) {
    static const std::map<std::string, const char *> names = {
        {"AC1009", "AutoCAD R12"}, {"AC1012", "AutoCAD R13"}, {"AC1014", "AutoCAD R14"},
        {"AC1015", "AutoCAD 2000"}, {"AC1018", "AutoCAD 2004"}, {"AC1021", "AutoCAD 2007"},
        {"AC1024", "AutoCAD 2010"}, {"AC1027", "AutoCAD 2013"}, {"AC1032", "AutoCAD 2018"},
    };
    const auto it = names.find(upper(acadver));
    return it == names.end() ? nullptr : it->second;
}

const char *unitName(long insunits) {
    switch (insunits) {
    case 1: return "inches";
    case 2: return "feet";
    case 4: return "millimetres";
    case 5: return "centimetres";
    case 6: return "metres";
    case 7: return "kilometres";
    case 10: return "yards";
    case 13: return "microns";
    case 14: return "decimetres";
    default: return nullptr;
    }
}

void readHeader(GroupReader &reader, DxfDrawing &out) {
    Group g;
    std::string variable;
    while (reader.next(g)) {
        if (g.code == 0) {
            if (g.value == "EOF") reader.pushBack(std::move(g));
            return;     // ENDSEC
        }
        if (g.code == 9) {
            variable = g.value;
        } else if (variable == "$ACADVER" && g.code == 1) {
            const char *name = versionName(g.value);
            out.version = name ? name : g.value;
        } else if (variable == "$INSUNITS" && g.code == 70) {
            const char *name = unitName(toInteger(g.value, 0));
            if (name) out.units = name;
        }
    }
}

// Only the layer table matters: frozen and switched-off layers are not drawn.
void readTables(GroupReader &reader, std::set<std::string> &hiddenLayers) {
    Group g;
    while (reader.next(g)) {
        if (g.code != 0) continue;
        if (g.value == "ENDSEC") return;
        if (g.value == "EOF") {
            reader.pushBack(std::move(g));
            return;
        }
        Entity record;
        record.type = g.value;
        readEntityBody(reader, record);
        if (record.type != "LAYER") continue;
        const bool frozen = (record.integer(70) & 1) != 0;
        const bool off = record.integer(62, 7) < 0;
        if (frozen || off) hiddenLayers.insert(upper(record.text(2)));
    }
}

void readBlocks(GroupReader &reader, std::map<std::string, Block> &blocks) {
    Group g;
    while (reader.next(g)) {
        if (g.code != 0) continue;
        if (g.value == "ENDSEC") return;
        if (g.value == "EOF") {
            reader.pushBack(std::move(g));
            return;
        }
        if (g.value != "BLOCK") continue;

        Entity header;
        readEntityBody(reader, header);
        const std::string name = upper(header.text(2));
        Block block;
        block.base = {header.real(10), header.real(20), header.real(30)};

        Entity entity;
        while (readEntity(reader, entity)) block.entities.push_back(std::move(entity));

        // Consume ENDBLK; anything else (ENDSEC, EOF) ends the section.
        if (!reader.next(g)) return;
        if (g.code == 0 && g.value == "ENDBLK") {
            Entity end;
            readEntityBody(reader, end);
        } else {
            reader.pushBack(std::move(g));
        }

        if (name.empty() || name.compare(0, 12, "*PAPER_SPACE") == 0) continue;
        blocks[name] = std::move(block);
    }
}

void readEntities(GroupReader &reader, Emitter &emitter) {
    const Xform identity;
    Entity entity;
    while (readEntity(reader, entity)) {
        if (entity.integer(67) == 1) continue;     // paper space
        emitter.emit(entity, identity, "0", 0);
    }
    Group g;
    if (reader.next(g) && !(g.code == 0 && g.value == "ENDSEC")) reader.pushBack(std::move(g));
}

struct FileCloser {
    void operator()(std::FILE *f) const { std::fclose(f); }
};

bool readDxfFile(const std::string &path, DxfDrawing &out, std::string &outError) {
    std::unique_ptr<std::FILE, FileCloser> file(std::fopen(path.c_str(), "rb"));
    if (!file) {
        outError = "Could not open this DXF file.";
        return false;
    }

    if (fseeko(file.get(), 0, SEEK_END) != 0) {
        outError = "Could not read this DXF file.";
        return false;
    }
    const off_t size = ftello(file.get());
    if (size > kMaxFileBytes) {
        outError = "This DXF file is too large to preview (over 256 MB).";
        return false;
    }
    std::rewind(file.get());

    char magic[18] = {};
    const size_t got = std::fread(magic, 1, sizeof(magic), file.get());
    if (got == sizeof(magic) && std::memcmp(magic, "AutoCAD Binary DXF", sizeof(magic)) == 0) {
        outError = "Binary DXF files are not supported yet.";
        return false;
    }
    if (got >= 4 && std::memcmp(magic, "AC10", 4) == 0) {
        outError = "This is a DWG file saved with a .dxf extension.";
        return false;
    }
    std::rewind(file.get());

    GroupReader reader(file.get());
    std::set<std::string> hiddenLayers;
    std::map<std::string, Block> blocks;
    Emitter emitter(blocks, hiddenLayers, out);

    Group g;
    while (reader.next(g)) {
        if (g.code != 0) continue;
        if (g.value == "EOF") break;
        if (g.value != "SECTION") continue;
        Group name;
        if (!reader.next(name)) break;
        if (name.code != 2) {
            reader.pushBack(std::move(name));
            continue;
        }
        if (name.value == "HEADER") {
            readHeader(reader, out);
        } else if (name.value == "TABLES") {
            readTables(reader, hiddenLayers);
        } else if (name.value == "BLOCKS") {
            readBlocks(reader, blocks);
        } else if (name.value == "ENTITIES") {
            readEntities(reader, emitter);
        } else {
            skipSection(reader);
        }
    }

    const bool empty = out.segments.empty() && out.faces.indices.empty();
    if (reader.malformed()) {
        if (empty) {
            outError = "This DXF file is malformed near line " + std::to_string(reader.line()) + ".";
            return false;
        }
        out.truncated = true;
    }
    if (empty) {
        outError = out.skippedTypes.empty()
            ? "This DXF file has no drawable geometry in model space."
            : "This DXF file has only text, hatches or other content that is not previewed yet.";
        return false;
    }
    return true;
}

} // namespace

bool readDxf(const std::string &path, DxfDrawing &out, std::string &outError) {
    try {
        return readDxfFile(path, out, outError);
    } catch (const std::bad_alloc &) {
        outError = "Out of memory reading this DXF file.";
    } catch (...) {
        outError = "Could not read this DXF file.";
    }
    out = DxfDrawing();
    return false;
}
