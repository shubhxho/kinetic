// kn_collision.hpp — broadphase, narrowphase and persistent contact manifolds.
//
// Sign convention: `normal` points from geom B toward geom A, so applying an
// impulse of +normal to A and -normal to B separates the pair. `depth` is the
// penetration depth and is positive when the shapes overlap.
#pragma once

#include <unordered_map>
#include <vector>

#include "kn_math.hpp"
#include "kn_model.hpp"

namespace kn {

struct AABB {
    Vec3 min = {1e30, 1e30, 1e30};
    Vec3 max = {-1e30, -1e30, -1e30};

    void expand(const Vec3 &p) {
        min.x = std::min(min.x, p.x); min.y = std::min(min.y, p.y); min.z = std::min(min.z, p.z);
        max.x = std::max(max.x, p.x); max.y = std::max(max.y, p.y); max.z = std::max(max.z, p.z);
    }
    void grow(Scalar m) {
        min -= Vec3(m, m, m);
        max += Vec3(m, m, m);
    }
    bool overlaps(const AABB &o) const {
        return !(max.x < o.min.x || min.x > o.max.x || max.y < o.min.y || min.y > o.max.y ||
                 max.z < o.min.z || min.z > o.max.z);
    }
    Vec3 center() const { return (min + max) * Scalar(0.5); }
};

struct ContactPoint {
    Vec3 position = Vec3::zero();  // world-space midpoint of the overlap
    Vec3 normal = Vec3::unitZ();   // unit, from B to A
    Scalar depth = 0;              // > 0 when penetrating

    Vec3 localA = Vec3::zero();    // anchor in link A's frame (for persistence)
    Vec3 localB = Vec3::zero();

    // Warm-start cache, in contact-frame coordinates (normal, tangent1, tangent2).
    Scalar impulseNormal = 0;
    Scalar impulseT1 = 0;
    Scalar impulseT2 = 0;
    Scalar impulseTorsion = 0;

    uint32_t featureId = 0;
    bool fresh = true;
};

struct Manifold {
    int geomA = -1, geomB = -1;
    int artA = -1, linkA = -1;
    int artB = -1, linkB = -1;
    Scalar friction = 1.0;
    Scalar torsionalFriction = 0.0;
    Scalar restitution = 0.0;
    Scalar timeConst = 0.02;
    Scalar dampingRatio = 1.0;
    int count = 0;
    ContactPoint points[4];

    void addPoint(const ContactPoint &p);
};

inline uint64_t manifoldKey(int a, int b) {
    return (uint64_t(uint32_t(a)) << 32) | uint32_t(b);
}

// ─────────────────────────────────────────────────────── support maps ──

// Support point of a geom in world space along direction `dir` (world frame).
Vec3 geomSupport(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes,
                 const Vec3 &dir);

AABB geomAABB(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes);

// ───────────────────────────────────────────────────────── narrowphase ──

// Result of a GJK/EPA query between two convex shapes.
struct ConvexResult {
    bool hit = false;
    Vec3 normal = Vec3::unitZ();  // from B to A
    Scalar depth = 0;
    Vec3 pointA = Vec3::zero();
    Vec3 pointB = Vec3::zero();
};

ConvexResult gjkEpa(const Geom &a, const Transform &poseA, const Geom &b, const Transform &poseB,
                    const std::vector<Mesh> &meshes, Scalar margin);

// Dispatches to the analytic routine for a pair when one exists, otherwise to
// GJK/EPA plus manifold enrichment. Returns the number of points written.
// `persistent` is set to true when the routine can only produce a single point
// per call, which tells the caller to accumulate points across steps.
int collidePair(const Geom &a, const Transform &poseA, const Geom &b, const Transform &poseB,
                const std::vector<Mesh> &meshes, Scalar margin, ContactPoint *out, int maxOut,
                bool *persistent = nullptr);

// ────────────────────────────────────────────────────────── raycasting ──

struct RayHit {
    bool hit = false;
    Scalar distance = 0;
    Vec3 point = Vec3::zero();
    Vec3 normal = Vec3::zero();
    int geom = -1;
    int articulation = -1;
    int link = -1;
};

bool rayGeom(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes,
             const Vec3 &origin, const Vec3 &dir, Scalar maxDist, Scalar &tOut, Vec3 &nOut);

// ────────────────────────────────────────────────────────── broadphase ──

// Sweep-and-prune over world-space AABBs. Rebuilt every step; for the scene
// sizes Kinetic targets (hundreds to a few thousand geoms) an incremental
// structure costs more in bookkeeping than the sort saves.
class Broadphase {
   public:
    void update(const std::vector<AABB> &boxes);
    const std::vector<std::pair<int, int>> &pairs() const { return pairs_; }

   private:
    struct Endpoint {
        Scalar value;
        int index;
        bool isMin;
    };
    std::vector<Endpoint> endpoints_;
    std::vector<std::pair<int, int>> pairs_;
    std::vector<int> active_;
};

}  // namespace kn
