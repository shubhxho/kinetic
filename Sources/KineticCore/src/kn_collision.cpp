// kn_collision.cpp — narrowphase implementations.
//
// Pairs that admit a closed form get one (they produce a full manifold in a
// single call and are far more stable for stacking). Everything else goes
// through GJK for separation / EPA for penetration and accumulates points into
// a persistent manifold across steps.

#include "kn_collision.hpp"

#include <algorithm>
#include <array>
#include <cstring>

namespace kn {

// ───────────────────────────────────────────────────────────── helpers ──

void Mesh::computeBounds() {
    aabbMin = Vec3(1e30, 1e30, 1e30);
    aabbMax = Vec3(-1e30, -1e30, -1e30);
    boundingRadius = 0;
    for (const Vec3 &v : vertices) {
        aabbMin.x = std::min(aabbMin.x, v.x);
        aabbMin.y = std::min(aabbMin.y, v.y);
        aabbMin.z = std::min(aabbMin.z, v.z);
        aabbMax.x = std::max(aabbMax.x, v.x);
        aabbMax.y = std::max(aabbMax.y, v.y);
        aabbMax.z = std::max(aabbMax.z, v.z);
        boundingRadius = std::max(boundingRadius, v.norm());
    }
    if (vertices.empty()) {
        aabbMin = aabbMax = Vec3::zero();
    }
}

Scalar Geom::boundingRadius() const {
    switch (type) {
        case GeomType::Sphere: return size.x;
        case GeomType::Box: return size.norm();
        case GeomType::Capsule:
        case GeomType::Cylinder: return std::sqrt(size.x * size.x + size.y * size.y);
        case GeomType::Plane: return 1e6;
        case GeomType::ConvexHull:
        case GeomType::Heightfield: return size.x > 0 ? size.x : 1.0;
    }
    return 1.0;
}

void Manifold::addPoint(const ContactPoint &p) {
    if (count < 4) {
        points[count++] = p;
        return;
    }
    // Replace the point that contributes least: prefer keeping deep, well-spread
    // points, so evict the shallowest point that is also closest to the new one.
    int worst = 0;
    Scalar worstScore = 1e30;
    for (int i = 0; i < 4; ++i) {
        Scalar spread = 1e30;
        for (int j = 0; j < 4; ++j)
            if (i != j) spread = std::min(spread, (points[i].position - points[j].position).norm());
        Scalar score = spread + points[i].depth * 4;
        if (score < worstScore) {
            worstScore = score;
            worst = i;
        }
    }
    Scalar newSpread = 1e30;
    for (int j = 0; j < 4; ++j)
        if (j != worst) newSpread = std::min(newSpread, (p.position - points[j].position).norm());
    if (newSpread + p.depth * 4 > worstScore) points[worst] = p;
}

Vec3 geomSupport(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes,
                 const Vec3 &dir) {
    Vec3 d = pose.rot.inverseRotate(dir);  // direction in the geom's local frame
    Vec3 local;
    switch (g.type) {
        case GeomType::Sphere:
            local = d.normalized() * g.size.x;
            break;
        case GeomType::Box:
            local = Vec3(std::copysign(g.size.x, d.x), std::copysign(g.size.y, d.y),
                         std::copysign(g.size.z, d.z));
            break;
        case GeomType::Capsule: {
            Vec3 axial(0, 0, std::copysign(g.size.y, d.z));
            local = axial + d.normalized() * g.size.x;
            break;
        }
        case GeomType::Cylinder: {
            Vec3 radial(d.x, d.y, 0);
            Scalar rn = radial.norm();
            radial = rn > kEps ? radial * (g.size.x / rn) : Vec3::zero();
            local = radial + Vec3(0, 0, std::copysign(g.size.y, d.z));
            break;
        }
        case GeomType::Plane:
            // A plane never participates in GJK; return a far point so that any
            // accidental use degrades gracefully instead of producing NaNs.
            local = Vec3(std::copysign(1e5, d.x), std::copysign(1e5, d.y), 0);
            break;
        case GeomType::ConvexHull:
        case GeomType::Heightfield: {
            local = Vec3::zero();
            if (g.meshIndex >= 0 && g.meshIndex < int(meshes.size())) {
                const Mesh &m = meshes[g.meshIndex];
                Scalar best = -1e30;
                for (const Vec3 &v : m.vertices) {
                    Scalar dot = v.dot(d);
                    if (dot > best) {
                        best = dot;
                        local = v;
                    }
                }
            }
            break;
        }
    }
    return pose.apply(local);
}

AABB geomAABB(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes) {
    AABB box;
    Mat3 R = pose.rot.toMatrix();
    auto absExtent = [&](const Vec3 &h) {
        Vec3 e;
        for (int i = 0; i < 3; ++i)
            e[i] = std::abs(R(i, 0)) * h.x + std::abs(R(i, 1)) * h.y + std::abs(R(i, 2)) * h.z;
        return e;
    };
    switch (g.type) {
        case GeomType::Sphere: {
            Vec3 r(g.size.x, g.size.x, g.size.x);
            box.min = pose.pos - r;
            box.max = pose.pos + r;
            break;
        }
        case GeomType::Box: {
            Vec3 e = absExtent(g.size);
            box.min = pose.pos - e;
            box.max = pose.pos + e;
            break;
        }
        case GeomType::Capsule:
        case GeomType::Cylinder: {
            Vec3 e = absExtent(Vec3(g.size.x, g.size.x, g.size.y));
            box.min = pose.pos - e;
            box.max = pose.pos + e;
            break;
        }
        case GeomType::Plane: {
            Vec3 n = pose.rot.rotate(Vec3::unitZ());
            const Scalar big = 1e4;
            box.min = Vec3(-big, -big, -big);
            box.max = Vec3(big, big, big);
            // Flatten along the plane normal so the broadphase can still reject.
            for (int i = 0; i < 3; ++i) {
                if (std::abs(n[i]) > 0.999) {
                    box.min[i] = pose.pos[i] - big;
                    box.max[i] = pose.pos[i] + 0.001;
                    if (n[i] < 0) {
                        box.min[i] = pose.pos[i] - 0.001;
                        box.max[i] = pose.pos[i] + big;
                    }
                }
            }
            break;
        }
        case GeomType::ConvexHull:
        case GeomType::Heightfield: {
            if (g.meshIndex >= 0 && g.meshIndex < int(meshes.size())) {
                const Mesh &m = meshes[g.meshIndex];
                Vec3 c = (m.aabbMin + m.aabbMax) * Scalar(0.5);
                Vec3 h = (m.aabbMax - m.aabbMin) * Scalar(0.5);
                Vec3 e = absExtent(h);
                Vec3 wc = pose.apply(c);
                box.min = wc - e;
                box.max = wc + e;
            } else {
                box.min = pose.pos;
                box.max = pose.pos;
            }
            break;
        }
    }
    return box;
}

// ─────────────────────────────────────────────────────────── GJK / EPA ──

namespace {

struct SupportVertex {
    Vec3 v;   // Minkowski difference point
    Vec3 pa;  // witness on A
    Vec3 pb;  // witness on B
};

struct ShapeProxy {
    const Geom *g;
    const Transform *pose;
    const std::vector<Mesh> *meshes;
    Vec3 support(const Vec3 &dir) const { return geomSupport(*g, *pose, *meshes, dir); }
};

SupportVertex minkowskiSupport(const ShapeProxy &A, const ShapeProxy &B, const Vec3 &dir) {
    SupportVertex s;
    s.pa = A.support(dir);
    s.pb = B.support(-dir);
    s.v = s.pa - s.pb;
    return s;
}

// Closest point to the origin on a simplex of `n` points. Returns the reduced
// simplex (writes back into `pts`) plus barycentric weights.
bool simplexClosest(SupportVertex *pts, int &n, Vec3 &closest, Scalar *weights) {
    auto setW = [&](std::initializer_list<Scalar> w) {
        int i = 0;
        for (Scalar x : w) weights[i++] = x;
    };
    if (n == 1) {
        closest = pts[0].v;
        setW({1});
        return closest.normSquared() < 1e-20;
    }
    if (n == 2) {
        Vec3 a = pts[0].v, b = pts[1].v;
        Vec3 ab = b - a;
        Scalar denom = ab.normSquared();
        Scalar t = denom > kEps ? clampf(-a.dot(ab) / denom, 0, 1) : 0;
        closest = a + ab * t;
        if (t <= 0) {
            n = 1;
            setW({1});
        } else if (t >= 1) {
            pts[0] = pts[1];
            n = 1;
            setW({1});
        } else {
            setW({1 - t, t});
        }
        return closest.normSquared() < 1e-20;
    }
    if (n == 3) {
        Vec3 a = pts[0].v, b = pts[1].v, c = pts[2].v;
        Vec3 ab = b - a, ac = c - a, ap = -a;
        Scalar d1 = ab.dot(ap), d2 = ac.dot(ap);
        if (d1 <= 0 && d2 <= 0) {
            n = 1;
            closest = a;
            setW({1});
            return closest.normSquared() < 1e-20;
        }
        Vec3 bp = -b;
        Scalar d3 = ab.dot(bp), d4 = ac.dot(bp);
        if (d3 >= 0 && d4 <= d3) {
            pts[0] = pts[1];
            n = 1;
            closest = b;
            setW({1});
            return closest.normSquared() < 1e-20;
        }
        Scalar vc = d1 * d4 - d3 * d2;
        if (vc <= 0 && d1 >= 0 && d3 <= 0) {
            Scalar t = d1 / (d1 - d3);
            closest = a + ab * t;
            n = 2;
            setW({1 - t, t});
            return closest.normSquared() < 1e-20;
        }
        Vec3 cp = -c;
        Scalar d5 = ab.dot(cp), d6 = ac.dot(cp);
        if (d6 >= 0 && d5 <= d6) {
            pts[0] = pts[2];
            n = 1;
            closest = c;
            setW({1});
            return closest.normSquared() < 1e-20;
        }
        Scalar vb = d5 * d2 - d1 * d6;
        if (vb <= 0 && d2 >= 0 && d6 <= 0) {
            Scalar t = d2 / (d2 - d6);
            closest = a + ac * t;
            pts[1] = pts[2];
            n = 2;
            setW({1 - t, t});
            return closest.normSquared() < 1e-20;
        }
        Scalar va = d3 * d6 - d5 * d4;
        if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
            Scalar t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
            closest = b + (c - b) * t;
            pts[0] = pts[1];
            pts[1] = pts[2];
            n = 2;
            setW({1 - t, t});
            return closest.normSquared() < 1e-20;
        }
        Scalar denom = 1 / (va + vb + vc);
        Scalar v = vb * denom, w = vc * denom;
        closest = a + ab * v + ac * w;
        setW({1 - v - w, v, w});
        return closest.normSquared() < 1e-20;
    }
    // n == 4: test the origin against each face; if inside all, we contain it.
    Vec3 a = pts[0].v, b = pts[1].v, c = pts[2].v, d = pts[3].v;
    auto outside = [](const Vec3 &p0, const Vec3 &p1, const Vec3 &p2, const Vec3 &p3) {
        Vec3 nrm = (p1 - p0).cross(p2 - p0);
        Scalar signP = nrm.dot(-p0);
        Scalar signD = nrm.dot(p3 - p0);
        return signP * signD < 0;
    };
    struct FaceTest {
        int i0, i1, i2, i3;
    };
    const FaceTest faces[4] = {{0, 1, 2, 3}, {0, 2, 3, 1}, {0, 3, 1, 2}, {1, 3, 2, 0}};
    const Vec3 v[4] = {a, b, c, d};
    Scalar bestDist = 1e30;
    SupportVertex bestPts[3];
    int bestN = 0;
    Scalar bestW[3] = {0, 0, 0};
    bool anyOutside = false;
    for (const FaceTest &f : faces) {
        if (!outside(v[f.i0], v[f.i1], v[f.i2], v[f.i3])) continue;
        anyOutside = true;
        SupportVertex tri[3] = {pts[f.i0], pts[f.i1], pts[f.i2]};
        int tn = 3;
        Vec3 cp;
        Scalar w3[3] = {0, 0, 0};
        simplexClosest(tri, tn, cp, w3);
        Scalar dist = cp.normSquared();
        if (dist < bestDist) {
            bestDist = dist;
            bestN = tn;
            for (int i = 0; i < tn; ++i) bestPts[i] = tri[i];
            for (int i = 0; i < 3; ++i) bestW[i] = w3[i];
            closest = cp;
        }
    }
    if (!anyOutside) {
        closest = Vec3::zero();
        return true;
    }
    n = bestN;
    for (int i = 0; i < bestN; ++i) pts[i] = bestPts[i];
    for (int i = 0; i < 3; ++i) weights[i] = bestW[i];
    return closest.normSquared() < 1e-20;
}

struct EpaFace {
    int a, b, c;
    Vec3 normal;
    Scalar distance;
    bool alive = true;
};

// Expanding polytope algorithm. Assumes `simplex` contains a tetrahedron that
// encloses the origin.
bool epa(const ShapeProxy &A, const ShapeProxy &B, SupportVertex *simplex, ConvexResult &out) {
    std::vector<SupportVertex> verts(simplex, simplex + 4);
    std::vector<EpaFace> faces;

    auto makeFace = [&](int a, int b, int c) {
        EpaFace f{a, b, c, Vec3::zero(), 0, true};
        Vec3 n = (verts[b].v - verts[a].v).cross(verts[c].v - verts[a].v);
        Scalar len = n.norm();
        if (len < 1e-14) {
            f.alive = false;
            return f;
        }
        n = n / len;
        Scalar d = n.dot(verts[a].v);
        if (d < 0) {
            n = -n;
            d = -d;
            std::swap(f.b, f.c);
        }
        f.normal = n;
        f.distance = d;
        return f;
    };

    faces.push_back(makeFace(0, 1, 2));
    faces.push_back(makeFace(0, 2, 3));
    faces.push_back(makeFace(0, 3, 1));
    faces.push_back(makeFace(1, 3, 2));

    const int kMaxIter = 64;
    for (int iter = 0; iter < kMaxIter; ++iter) {
        int best = -1;
        Scalar bestDist = 1e30;
        for (int i = 0; i < int(faces.size()); ++i) {
            if (!faces[i].alive) continue;
            if (faces[i].distance < bestDist) {
                bestDist = faces[i].distance;
                best = i;
            }
        }
        if (best < 0) return false;

        EpaFace face = faces[best];
        SupportVertex sup = minkowskiSupport(A, B, face.normal);
        Scalar d = sup.v.dot(face.normal);
        if (d - bestDist < 1e-6 || iter == kMaxIter - 1) {
            // Converged: recover witness points via barycentric coordinates on
            // the closest face.
            const SupportVertex &va = verts[face.a];
            const SupportVertex &vb = verts[face.b];
            const SupportVertex &vc = verts[face.c];
            Vec3 p = face.normal * face.distance;
            Vec3 v0 = vb.v - va.v, v1 = vc.v - va.v, v2 = p - va.v;
            Scalar d00 = v0.dot(v0), d01 = v0.dot(v1), d11 = v1.dot(v1);
            Scalar d20 = v2.dot(v0), d21 = v2.dot(v1);
            Scalar denom = d00 * d11 - d01 * d01;
            Scalar u = 1, vw = 0, w = 0;
            if (std::abs(denom) > 1e-18) {
                vw = (d11 * d20 - d01 * d21) / denom;
                w = (d00 * d21 - d01 * d20) / denom;
                u = 1 - vw - w;
            }
            u = clampf(u, 0, 1);
            vw = clampf(vw, 0, 1);
            w = clampf(w, 0, 1);
            Scalar s = u + vw + w;
            if (s < kEps) return false;
            u /= s; vw /= s; w /= s;
            out.hit = true;
            out.depth = face.distance;
            out.normal = face.normal;  // from B to A
            out.pointA = va.pa * u + vb.pa * vw + vc.pa * w;
            out.pointB = va.pb * u + vb.pb * vw + vc.pb * w;
            return true;
        }

        // Remove every face the new point can see and re-triangulate the hole.
        int newIndex = int(verts.size());
        verts.push_back(sup);
        std::vector<std::pair<int, int>> horizon;
        for (auto &f : faces) {
            if (!f.alive) continue;
            if (f.normal.dot(sup.v - verts[f.a].v) > 1e-12) {
                f.alive = false;
                auto addEdge = [&](int i, int j) {
                    for (auto it = horizon.begin(); it != horizon.end(); ++it) {
                        if (it->first == j && it->second == i) {
                            horizon.erase(it);
                            return;
                        }
                    }
                    horizon.emplace_back(i, j);
                };
                addEdge(f.a, f.b);
                addEdge(f.b, f.c);
                addEdge(f.c, f.a);
            }
        }
        if (horizon.empty()) return false;
        for (auto &e : horizon) faces.push_back(makeFace(e.first, e.second, newIndex));
    }
    return false;
}

}  // namespace

ConvexResult gjkEpa(const Geom &a, const Transform &poseA, const Geom &b, const Transform &poseB,
                    const std::vector<Mesh> &meshes, Scalar margin) {
    ShapeProxy A{&a, &poseA, &meshes};
    ShapeProxy B{&b, &poseB, &meshes};
    ConvexResult res;

    SupportVertex simplex[4];
    int n = 0;
    Vec3 dir = poseA.pos - poseB.pos;
    if (dir.normSquared() < 1e-16) dir = Vec3::unitX();

    simplex[n++] = minkowskiSupport(A, B, dir);
    dir = -simplex[0].v;

    Scalar weights[4] = {0, 0, 0, 0};
    Vec3 closest = simplex[0].v;
    bool containsOrigin = false;

    for (int iter = 0; iter < 64; ++iter) {
        if (dir.normSquared() < 1e-20) {
            containsOrigin = true;
            break;
        }
        SupportVertex s = minkowskiSupport(A, B, dir.normalized());
        // No progress toward the origin: the shapes are separated.
        if (s.v.dot(dir.normalized()) < closest.norm() - 1e-10 && n > 0 && closest.norm() > 1e-9) {
            if (s.v.dot(dir.normalized()) <= 0) break;
        }
        bool duplicate = false;
        for (int i = 0; i < n; ++i)
            if ((simplex[i].v - s.v).normSquared() < 1e-18) duplicate = true;
        if (duplicate) break;

        simplex[n++] = s;
        containsOrigin = simplexClosest(simplex, n, closest, weights);
        if (containsOrigin || n == 4) {
            if (n == 4) containsOrigin = true;
            break;
        }
        dir = -closest;
    }

    if (containsOrigin && n == 4) {
        if (epa(A, B, simplex, res)) return res;
    }

    // Separated (or EPA failed): report the closest features. Weights line up
    // with the reduced simplex from the last call to simplexClosest.
    Vec3 pa = Vec3::zero(), pb = Vec3::zero();
    Scalar wsum = 0;
    for (int i = 0; i < n; ++i) {
        pa += simplex[i].pa * weights[i];
        pb += simplex[i].pb * weights[i];
        wsum += weights[i];
    }
    if (wsum > kEps) {
        pa = pa / wsum;
        pb = pb / wsum;
    } else {
        pa = simplex[0].pa;
        pb = simplex[0].pb;
    }
    Vec3 delta = pa - pb;
    Scalar dist = delta.norm();
    if (dist < margin && dist > 1e-9) {
        res.hit = true;
        res.normal = delta / dist;
        res.depth = -dist;
        res.pointA = pa;
        res.pointB = pb;
    }
    return res;
}

// ────────────────────────────────────────────────────── analytic pairs ──

namespace {

ContactPoint makePoint(const Vec3 &onA, const Vec3 &onB, const Vec3 &normal, Scalar depth,
                       const Transform &poseA, const Transform &poseB, uint32_t feature) {
    ContactPoint cp;
    cp.normal = normal;
    cp.depth = depth;
    cp.position = (onA + onB) * Scalar(0.5);
    cp.localA = poseA.applyInverse(onA);
    cp.localB = poseB.applyInverse(onB);
    cp.featureId = feature;
    return cp;
}

int sphereSphere(const Geom &a, const Transform &pa, const Geom &b, const Transform &pb,
                 Scalar margin, ContactPoint *out) {
    Vec3 d = pa.pos - pb.pos;
    Scalar dist = d.norm();
    Scalar rsum = a.size.x + b.size.x;
    if (dist > rsum + margin) return 0;
    Vec3 n = dist > kEps ? d / dist : Vec3::unitZ();
    out[0] = makePoint(pa.pos - n * a.size.x, pb.pos + n * b.size.x, n, rsum - dist, pa, pb, 0);
    return 1;
}

Vec3 closestPointOnBox(const Vec3 &p, const Vec3 &halfExtents) {
    return {clampf(p.x, -halfExtents.x, halfExtents.x), clampf(p.y, -halfExtents.y, halfExtents.y),
            clampf(p.z, -halfExtents.z, halfExtents.z)};
}

int sphereBox(const Geom &sphere, const Transform &ps, const Geom &box, const Transform &pb,
              Scalar margin, ContactPoint *out) {
    Vec3 local = pb.applyInverse(ps.pos);
    Vec3 cp = closestPointOnBox(local, box.size);
    Vec3 delta = local - cp;
    Scalar dist = delta.norm();
    bool inside = dist < 1e-9;
    Vec3 nLocal;
    if (inside) {
        // Centre is inside the box: push out along the shallowest face.
        Scalar dx = box.size.x - std::abs(local.x);
        Scalar dy = box.size.y - std::abs(local.y);
        Scalar dz = box.size.z - std::abs(local.z);
        if (dx <= dy && dx <= dz) {
            nLocal = Vec3(std::copysign(1.0, local.x), 0, 0);
            cp = local + nLocal * dx;
            dist = -dx;
        } else if (dy <= dz) {
            nLocal = Vec3(0, std::copysign(1.0, local.y), 0);
            cp = local + nLocal * dy;
            dist = -dy;
        } else {
            nLocal = Vec3(0, 0, std::copysign(1.0, local.z));
            cp = local + nLocal * dz;
            dist = -dz;
        }
    } else {
        nLocal = delta / dist;
    }
    Scalar depth = sphere.size.x - dist;
    if (depth < -margin) return 0;
    Vec3 n = pb.applyVector(nLocal);  // from box (B) toward sphere (A)
    Vec3 onB = pb.apply(cp);
    Vec3 onA = ps.pos - n * sphere.size.x;
    out[0] = makePoint(onA, onB, n, depth, ps, pb, 0);
    return 1;
}

void capsuleSegment(const Geom &g, const Transform &p, Vec3 &p0, Vec3 &p1) {
    Vec3 axis = p.applyVector(Vec3(0, 0, g.size.y));
    p0 = p.pos - axis;
    p1 = p.pos + axis;
}

Vec3 closestOnSegment(const Vec3 &a, const Vec3 &b, const Vec3 &p, Scalar &t) {
    Vec3 ab = b - a;
    Scalar denom = ab.normSquared();
    t = denom > kEps ? clampf((p - a).dot(ab) / denom, 0, 1) : 0;
    return a + ab * t;
}

// Closest points between two segments (Ericson, Real-Time Collision Detection).
void closestSegmentSegment(const Vec3 &p1, const Vec3 &q1, const Vec3 &p2, const Vec3 &q2, Vec3 &c1,
                           Vec3 &c2, Scalar &s, Scalar &t) {
    Vec3 d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
    Scalar a = d1.normSquared(), e = d2.normSquared(), f = d2.dot(r);
    if (a <= kEps && e <= kEps) {
        s = t = 0;
        c1 = p1;
        c2 = p2;
        return;
    }
    if (a <= kEps) {
        s = 0;
        t = clampf(f / e, 0, 1);
    } else {
        Scalar c = d1.dot(r);
        if (e <= kEps) {
            t = 0;
            s = clampf(-c / a, 0, 1);
        } else {
            Scalar b = d1.dot(d2);
            Scalar denom = a * e - b * b;
            s = denom > kEps ? clampf((b * f - c * e) / denom, 0, 1) : 0;
            t = (b * s + f) / e;
            if (t < 0) {
                t = 0;
                s = clampf(-c / a, 0, 1);
            } else if (t > 1) {
                t = 1;
                s = clampf((b - c) / a, 0, 1);
            }
        }
    }
    c1 = p1 + d1 * s;
    c2 = p2 + d2 * t;
}

int sphereCapsule(const Geom &s, const Transform &ps, const Geom &c, const Transform &pc,
                  Scalar margin, ContactPoint *out) {
    Vec3 a, b;
    capsuleSegment(c, pc, a, b);
    Scalar t;
    Vec3 cp = closestOnSegment(a, b, ps.pos, t);
    Vec3 d = ps.pos - cp;
    Scalar dist = d.norm();
    Scalar rsum = s.size.x + c.size.x;
    if (dist > rsum + margin) return 0;
    Vec3 n = dist > kEps ? d / dist : Vec3::unitZ();
    out[0] = makePoint(ps.pos - n * s.size.x, cp + n * c.size.x, n, rsum - dist, ps, pc, 0);
    return 1;
}

int capsuleCapsule(const Geom &a, const Transform &pa, const Geom &b, const Transform &pb,
                   Scalar margin, ContactPoint *out) {
    Vec3 a0, a1, b0, b1;
    capsuleSegment(a, pa, a0, a1);
    capsuleSegment(b, pb, b0, b1);
    Vec3 c1, c2;
    Scalar s, t;
    closestSegmentSegment(a0, a1, b0, b1, c1, c2, s, t);
    Vec3 d = c1 - c2;
    Scalar dist = d.norm();
    Scalar rsum = a.size.x + b.size.x;
    if (dist > rsum + margin) return 0;
    Vec3 n = dist > kEps ? d / dist : Vec3::unitZ();

    // Near-parallel capsules get a two-point manifold so they cannot pivot.
    Vec3 da = (a1 - a0).normalized(), db = (b1 - b0).normalized();
    int count = 0;
    if (std::abs(da.dot(db)) > 0.995 && (a1 - a0).norm() > kEps && (b1 - b0).norm() > kEps) {
        // Overlap the two segments along the shared direction.
        Scalar la = (a1 - a0).norm();
        Vec3 origin = a0;
        Scalar bs = (b0 - origin).dot(da), be = (b1 - origin).dot(da);
        if (bs > be) std::swap(bs, be);
        Scalar lo = std::max(Scalar(0), bs), hi = std::min(la, be);
        if (hi > lo + 1e-6) {
            for (int i = 0; i < 2; ++i) {
                Scalar u = i == 0 ? lo : hi;
                Vec3 pA = origin + da * u;
                Scalar tt;
                Vec3 pB = closestOnSegment(b0, b1, pA, tt);
                Vec3 dd = pA - pB;
                Scalar dl = dd.norm();
                Vec3 nn = dl > kEps ? dd / dl : n;
                Scalar depth = rsum - dl;
                if (depth < -margin) continue;
                out[count] = makePoint(pA - nn * a.size.x, pB + nn * b.size.x, nn, depth, pa, pb,
                                       uint32_t(i));
                count++;
            }
            if (count > 0) return count;
        }
    }
    out[0] = makePoint(c1 - n * a.size.x, c2 + n * b.size.x, n, rsum - dist, pa, pb, 0);
    return 1;
}

// Plane is always geom B; the returned normal points from the plane toward A.
int planeVsPoints(const Transform &planePose, const Vec3 *pts, int count, Scalar radius,
                  Scalar margin, const Transform &pa, ContactPoint *out, int maxOut) {
    Vec3 n = planePose.applyVector(Vec3::unitZ());
    Scalar d0 = n.dot(planePose.pos);

    struct Cand {
        Scalar depth;
        Vec3 p;
        int id;
    };
    std::array<Cand, 64> cands;
    int nc = 0;
    for (int i = 0; i < count && nc < 64; ++i) {
        Scalar dist = n.dot(pts[i]) - d0 - radius;
        if (dist < margin) cands[nc++] = {-dist, pts[i], i};
    }
    if (nc == 0) return 0;
    std::sort(cands.begin(), cands.begin() + nc,
              [](const Cand &x, const Cand &y) { return x.depth > y.depth; });
    int emit = std::min(nc, maxOut);
    for (int i = 0; i < emit; ++i) {
        Vec3 onA = cands[i].p - n * radius;
        Vec3 onB = onA + n * cands[i].depth;
        out[i] = makePoint(onA, onB, n, cands[i].depth, pa, planePose, uint32_t(cands[i].id));
    }
    return emit;
}

int shapeVsPlane(const Geom &a, const Transform &pa, const Geom &plane, const Transform &pp,
                 const std::vector<Mesh> &meshes, Scalar margin, ContactPoint *out, int maxOut) {
    Vec3 n = pp.applyVector(Vec3::unitZ());
    switch (a.type) {
        case GeomType::Sphere:
            return planeVsPoints(pp, &pa.pos, 1, a.size.x, margin, pa, out, maxOut);
        case GeomType::Box: {
            Vec3 verts[8];
            int k = 0;
            for (int i = 0; i < 8; ++i)
                verts[k++] = pa.apply(Vec3((i & 1) ? a.size.x : -a.size.x,
                                           (i & 2) ? a.size.y : -a.size.y,
                                           (i & 4) ? a.size.z : -a.size.z));
            return planeVsPoints(pp, verts, 8, 0, margin, pa, out, maxOut);
        }
        case GeomType::Capsule: {
            Vec3 p0, p1;
            capsuleSegment(a, pa, p0, p1);
            Vec3 pts[2] = {p0, p1};
            return planeVsPoints(pp, pts, 2, a.size.x, margin, pa, out, maxOut);
        }
        case GeomType::Cylinder: {
            Vec3 axis = pa.applyVector(Vec3::unitZ());
            Scalar align = axis.dot(n);
            std::array<Vec3, 16> pts;
            int np = 0;
            // Sample the rim of both caps; the sort in planeVsPoints keeps the
            // deepest points, which covers upright, tipped and lying poses.
            Vec3 t1, t2;
            orthoBasis(axis, t1, t2);
            const int kSamples = std::abs(align) > 0.9 ? 4 : 8;
            for (int s = 0; s < kSamples; ++s) {
                Scalar ang = 2 * kPi * s / kSamples;
                Vec3 radial = (t1 * std::cos(ang) + t2 * std::sin(ang)) * a.size.x;
                pts[np++] = pa.pos + axis * a.size.y + radial;
                pts[np++] = pa.pos - axis * a.size.y + radial;
            }
            return planeVsPoints(pp, pts.data(), np, 0, margin, pa, out, maxOut);
        }
        case GeomType::ConvexHull: {
            if (a.meshIndex < 0 || a.meshIndex >= int(meshes.size())) return 0;
            const Mesh &m = meshes[a.meshIndex];
            std::vector<Vec3> world;
            world.reserve(m.vertices.size());
            for (const Vec3 &v : m.vertices) world.push_back(pa.apply(v));
            return planeVsPoints(pp, world.data(), int(world.size()), 0, margin, pa, out, maxOut);
        }
        default:
            return 0;
    }
}

// ── box / box: SAT with reference-face clipping ────────────────────────

struct BoxAxes {
    Vec3 c;
    Vec3 axis[3];
    Vec3 h;
};

BoxAxes boxAxes(const Geom &g, const Transform &p) {
    BoxAxes b;
    b.c = p.pos;
    Mat3 R = p.rot.toMatrix();
    b.axis[0] = R.col(0);
    b.axis[1] = R.col(1);
    b.axis[2] = R.col(2);
    b.h = g.size;
    return b;
}

Scalar boxProject(const BoxAxes &b, const Vec3 &axis) {
    return std::abs(axis.dot(b.axis[0])) * b.h.x + std::abs(axis.dot(b.axis[1])) * b.h.y +
           std::abs(axis.dot(b.axis[2])) * b.h.z;
}

int boxBox(const Geom &ga, const Transform &pa, const Geom &gb, const Transform &pb, Scalar margin,
           ContactPoint *out, int maxOut) {
    BoxAxes A = boxAxes(ga, pa), B = boxAxes(gb, pb);
    Vec3 t = A.c - B.c;

    Scalar bestDepth = 1e30;
    Vec3 bestAxis;
    int bestType = -1;  // 0 = face of A, 1 = face of B, 2 = edge-edge
    int bestIndex = 0;

    auto test = [&](const Vec3 &axisIn, int type, int index) {
        Scalar len = axisIn.norm();
        if (len < 1e-8) return true;
        Vec3 axis = axisIn / len;
        Scalar overlap = boxProject(A, axis) + boxProject(B, axis) - std::abs(axis.dot(t));
        if (overlap < -margin) return false;
        // Bias toward face axes; edge axes are numerically noisier.
        Scalar biased = overlap + (type == 2 ? 1e-3 : 0);
        if (biased < bestDepth) {
            bestDepth = biased;
            bestAxis = axis.dot(t) < 0 ? -axis : axis;  // point from B to A
            bestType = type;
            bestIndex = index;
        }
        return true;
    };

    for (int i = 0; i < 3; ++i)
        if (!test(A.axis[i], 0, i)) return 0;
    for (int i = 0; i < 3; ++i)
        if (!test(B.axis[i], 1, i)) return 0;
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j)
            if (!test(A.axis[i].cross(B.axis[j]), 2, i * 3 + j)) return 0;

    if (bestType < 0) return 0;
    Vec3 n = bestAxis;  // from B to A

    if (bestType == 2) {
        // Edge-edge: closest points between the two witness edges.
        int i = bestIndex / 3, j = bestIndex % 3;
        Vec3 ea = A.axis[i], eb = B.axis[j];
        Vec3 pA = A.c, pB = B.c;
        for (int k = 0; k < 3; ++k) {
            if (k != i) pA -= A.axis[k] * std::copysign(A.h[k], A.axis[k].dot(n));
            if (k != j) pB += B.axis[k] * std::copysign(B.h[k], B.axis[k].dot(n));
        }
        Vec3 c1, c2;
        Scalar s, u;
        closestSegmentSegment(pA - ea * A.h[i], pA + ea * A.h[i], pB - eb * B.h[j],
                              pB + eb * B.h[j], c1, c2, s, u);
        out[0] = makePoint(c1, c2, n, bestDepth, pa, pb, 100);
        return 1;
    }

    // Face case: the reference box owns the face whose axis won.
    const BoxAxes &ref = bestType == 0 ? A : B;
    const BoxAxes &inc = bestType == 0 ? B : A;
    const Transform &refPose = bestType == 0 ? pa : pb;
    const Transform &incPose = bestType == 0 ? pb : pa;
    Vec3 refNormal = bestType == 0 ? -n : n;  // outward from the reference face

    int refAxis = 0;
    Scalar bestDot = -1;
    for (int i = 0; i < 3; ++i) {
        Scalar d = std::abs(ref.axis[i].dot(refNormal));
        if (d > bestDot) {
            bestDot = d;
            refAxis = i;
        }
    }
    Scalar refSign = ref.axis[refAxis].dot(refNormal) < 0 ? -1 : 1;
    Vec3 refCenter = ref.c + ref.axis[refAxis] * (refSign * ref.h[refAxis]);
    int refU = (refAxis + 1) % 3, refV = (refAxis + 2) % 3;

    // Incident face: the face of `inc` most anti-parallel to the reference normal.
    int incAxis = 0;
    Scalar minDot = 1e30;
    Scalar incSign = 1;
    for (int i = 0; i < 3; ++i) {
        Scalar d = inc.axis[i].dot(refNormal);
        if (d < minDot) {
            minDot = d;
            incAxis = i;
            incSign = 1;
        }
        if (-d < minDot) {
            minDot = -d;
            incAxis = i;
            incSign = -1;
        }
    }
    int incU = (incAxis + 1) % 3, incV = (incAxis + 2) % 3;
    Vec3 incCenter = inc.c + inc.axis[incAxis] * (incSign * inc.h[incAxis]);
    Vec3 quad[4];
    quad[0] = incCenter - inc.axis[incU] * inc.h[incU] - inc.axis[incV] * inc.h[incV];
    quad[1] = incCenter + inc.axis[incU] * inc.h[incU] - inc.axis[incV] * inc.h[incV];
    quad[2] = incCenter + inc.axis[incU] * inc.h[incU] + inc.axis[incV] * inc.h[incV];
    quad[3] = incCenter - inc.axis[incU] * inc.h[incU] + inc.axis[incV] * inc.h[incV];

    // Clip the incident quad against the four side planes of the reference face.
    std::vector<Vec3> poly(quad, quad + 4);
    auto clip = [&](const Vec3 &planeN, Scalar planeD) {
        std::vector<Vec3> outPoly;
        outPoly.reserve(poly.size() + 2);
        for (size_t i = 0; i < poly.size(); ++i) {
            const Vec3 &cur = poly[i];
            const Vec3 &nxt = poly[(i + 1) % poly.size()];
            Scalar dc = planeN.dot(cur) - planeD;
            Scalar dn = planeN.dot(nxt) - planeD;
            if (dc <= 0) outPoly.push_back(cur);
            if ((dc > 0) != (dn > 0)) {
                Scalar tt = dc / (dc - dn);
                outPoly.push_back(cur + (nxt - cur) * tt);
            }
        }
        poly.swap(outPoly);
    };
    clip(ref.axis[refU], ref.axis[refU].dot(ref.c) + ref.h[refU]);
    clip(-ref.axis[refU], -ref.axis[refU].dot(ref.c) + ref.h[refU]);
    clip(ref.axis[refV], ref.axis[refV].dot(ref.c) + ref.h[refV]);
    clip(-ref.axis[refV], -ref.axis[refV].dot(ref.c) + ref.h[refV]);
    if (poly.empty()) return 0;

    Scalar refPlaneD = refNormal.dot(refCenter);
    struct Cand {
        Scalar depth;
        Vec3 p;
    };
    std::vector<Cand> cands;
    for (const Vec3 &p : poly) {
        Scalar sep = refNormal.dot(p) - refPlaneD;
        if (sep < margin) cands.push_back({-sep, p});
    }
    if (cands.empty()) return 0;
    std::sort(cands.begin(), cands.end(),
              [](const Cand &x, const Cand &y) { return x.depth > y.depth; });
    int emit = std::min(int(cands.size()), maxOut);
    for (int i = 0; i < emit; ++i) {
        Vec3 pOnInc = cands[i].p;
        Vec3 pOnRef = pOnInc + refNormal * cands[i].depth;
        Vec3 onA = bestType == 0 ? pOnRef : pOnInc;
        Vec3 onB = bestType == 0 ? pOnInc : pOnRef;
        out[i] = makePoint(onA, onB, n, cands[i].depth, pa, pb, uint32_t(i));
    }
    (void)refPose;
    (void)incPose;
    return emit;
}

void flipContacts(ContactPoint *out, int count) {
    for (int i = 0; i < count; ++i) {
        out[i].normal = -out[i].normal;
        std::swap(out[i].localA, out[i].localB);
    }
}

}  // namespace

int collidePair(const Geom &a, const Transform &poseA, const Geom &b, const Transform &poseB,
                const std::vector<Mesh> &meshes, Scalar margin, ContactPoint *out, int maxOut,
                bool *persistent) {
    if (persistent) *persistent = false;
    const GeomType ta = a.type, tb = b.type;

    auto both = [&](GeomType x, GeomType y) { return ta == x && tb == y; };

    if (both(GeomType::Sphere, GeomType::Sphere)) return sphereSphere(a, poseA, b, poseB, margin, out);
    if (both(GeomType::Sphere, GeomType::Box)) return sphereBox(a, poseA, b, poseB, margin, out);
    if (both(GeomType::Box, GeomType::Sphere)) {
        int n = sphereBox(b, poseB, a, poseA, margin, out);
        flipContacts(out, n);
        return n;
    }
    if (both(GeomType::Sphere, GeomType::Capsule))
        return sphereCapsule(a, poseA, b, poseB, margin, out);
    if (both(GeomType::Capsule, GeomType::Sphere)) {
        int n = sphereCapsule(b, poseB, a, poseA, margin, out);
        flipContacts(out, n);
        return n;
    }
    if (both(GeomType::Capsule, GeomType::Capsule))
        return capsuleCapsule(a, poseA, b, poseB, margin, out);
    if (both(GeomType::Box, GeomType::Box)) return boxBox(a, poseA, b, poseB, margin, out, maxOut);

    if (tb == GeomType::Plane) return shapeVsPlane(a, poseA, b, poseB, meshes, margin, out, maxOut);
    if (ta == GeomType::Plane) {
        int n = shapeVsPlane(b, poseB, a, poseA, meshes, margin, out, maxOut);
        flipContacts(out, n);
        return n;
    }

    // Generic convex path.
    ConvexResult r = gjkEpa(a, poseA, b, poseB, meshes, margin);
    if (!r.hit) return 0;
    if (persistent) *persistent = true;
    out[0] = makePoint(r.pointA, r.pointB, r.normal, r.depth, poseA, poseB, 0);
    return 1;
}

// ────────────────────────────────────────────────────────── raycasting ──

bool rayGeom(const Geom &g, const Transform &pose, const std::vector<Mesh> &meshes,
             const Vec3 &origin, const Vec3 &dir, Scalar maxDist, Scalar &tOut, Vec3 &nOut) {
    // Work in the geom's local frame.
    Vec3 o = pose.applyInverse(origin);
    Vec3 d = pose.rot.inverseRotate(dir);

    auto emit = [&](Scalar t, const Vec3 &nLocal) {
        if (t < 0 || t > maxDist) return false;
        tOut = t;
        nOut = pose.applyVector(nLocal).normalized();
        return true;
    };

    switch (g.type) {
        case GeomType::Sphere: {
            Scalar b = o.dot(d);
            Scalar c = o.normSquared() - g.size.x * g.size.x;
            Scalar disc = b * b - c;
            if (disc < 0) return false;
            Scalar sq = std::sqrt(disc);
            Scalar t = -b - sq;
            if (t < 0) t = -b + sq;
            if (t < 0) return false;
            return emit(t, (o + d * t).normalized());
        }
        case GeomType::Box: {
            Scalar tmin = 0, tmax = maxDist;
            int axis = 0;
            Scalar sign = 1;
            for (int i = 0; i < 3; ++i) {
                if (std::abs(d[i]) < 1e-12) {
                    if (std::abs(o[i]) > g.size[i]) return false;
                    continue;
                }
                Scalar inv = 1 / d[i];
                Scalar t1 = (-g.size[i] - o[i]) * inv;
                Scalar t2 = (g.size[i] - o[i]) * inv;
                Scalar s = -1;
                if (t1 > t2) {
                    std::swap(t1, t2);
                    s = 1;
                }
                if (t1 > tmin) {
                    tmin = t1;
                    axis = i;
                    sign = s;
                }
                tmax = std::min(tmax, t2);
                if (tmin > tmax) return false;
            }
            Vec3 n = Vec3::zero();
            n[axis] = sign;
            return emit(tmin, n);
        }
        case GeomType::Plane: {
            if (std::abs(d.z) < 1e-12) return false;
            Scalar t = -o.z / d.z;
            if (t < 0) return false;
            return emit(t, Vec3(0, 0, d.z < 0 ? 1 : -1));
        }
        case GeomType::Capsule:
        case GeomType::Cylinder: {
            // Infinite-cylinder intersection, then cap handling.
            Scalar r = g.size.x, hl = g.size.y;
            Scalar a2 = d.x * d.x + d.y * d.y;
            Scalar b2 = o.x * d.x + o.y * d.y;
            Scalar c2 = o.x * o.x + o.y * o.y - r * r;
            Scalar bestT = 1e30;
            Vec3 bestN;
            if (a2 > 1e-14) {
                Scalar disc = b2 * b2 - a2 * c2;
                if (disc >= 0) {
                    Scalar sq = std::sqrt(disc);
                    for (Scalar t : {(-b2 - sq) / a2, (-b2 + sq) / a2}) {
                        if (t < 0 || t > bestT) continue;
                        Vec3 p = o + d * t;
                        if (std::abs(p.z) <= hl) {
                            bestT = t;
                            bestN = Vec3(p.x, p.y, 0).normalized();
                        }
                    }
                }
            }
            if (g.type == GeomType::Cylinder) {
                if (std::abs(d.z) > 1e-12) {
                    for (Scalar zc : {-hl, hl}) {
                        Scalar t = (zc - o.z) / d.z;
                        if (t < 0 || t > bestT) continue;
                        Vec3 p = o + d * t;
                        if (p.x * p.x + p.y * p.y <= r * r) {
                            bestT = t;
                            bestN = Vec3(0, 0, zc > 0 ? 1 : -1);
                        }
                    }
                }
            } else {
                for (Scalar zc : {-hl, hl}) {
                    Vec3 center(0, 0, zc);
                    Vec3 oc = o - center;
                    Scalar b3 = oc.dot(d);
                    Scalar c3 = oc.normSquared() - r * r;
                    Scalar disc = b3 * b3 - c3;
                    if (disc < 0) continue;
                    Scalar sq = std::sqrt(disc);
                    for (Scalar t : {-b3 - sq, -b3 + sq}) {
                        if (t < 0 || t > bestT) continue;
                        Vec3 p = o + d * t;
                        if ((zc > 0 && p.z >= hl) || (zc < 0 && p.z <= -hl)) {
                            bestT = t;
                            bestN = (p - center).normalized();
                        }
                    }
                }
            }
            if (bestT > maxDist) return false;
            return emit(bestT, bestN);
        }
        case GeomType::ConvexHull:
        case GeomType::Heightfield: {
            if (g.meshIndex < 0 || g.meshIndex >= int(meshes.size())) return false;
            const Mesh &m = meshes[g.meshIndex];
            Scalar bestT = 1e30;
            Vec3 bestN;
            for (size_t i = 0; i + 2 < m.faces.size(); i += 3) {
                const Vec3 &v0 = m.vertices[m.faces[i]];
                const Vec3 &v1 = m.vertices[m.faces[i + 1]];
                const Vec3 &v2 = m.vertices[m.faces[i + 2]];
                Vec3 e1 = v1 - v0, e2 = v2 - v0;
                Vec3 pv = d.cross(e2);
                Scalar det = e1.dot(pv);
                if (std::abs(det) < 1e-14) continue;
                Scalar invDet = 1 / det;
                Vec3 tv = o - v0;
                Scalar u = tv.dot(pv) * invDet;
                if (u < 0 || u > 1) continue;
                Vec3 qv = tv.cross(e1);
                Scalar vpar = d.dot(qv) * invDet;
                if (vpar < 0 || u + vpar > 1) continue;
                Scalar t = e2.dot(qv) * invDet;
                if (t < 0 || t > bestT) continue;
                bestT = t;
                bestN = e1.cross(e2).normalized();
                if (bestN.dot(d) > 0) bestN = -bestN;
            }
            if (bestT > maxDist) return false;
            return emit(bestT, bestN);
        }
    }
    return false;
}

// ────────────────────────────────────────────────────────── broadphase ──

void Broadphase::update(const std::vector<AABB> &boxes) {
    pairs_.clear();
    endpoints_.clear();
    endpoints_.reserve(boxes.size() * 2);
    for (int i = 0; i < int(boxes.size()); ++i) {
        if (boxes[i].min.x > boxes[i].max.x) continue;  // disabled geom
        endpoints_.push_back({boxes[i].min.x, i, true});
        endpoints_.push_back({boxes[i].max.x, i, false});
    }
    std::sort(endpoints_.begin(), endpoints_.end(), [](const Endpoint &a, const Endpoint &b) {
        if (a.value != b.value) return a.value < b.value;
        if (a.isMin != b.isMin) return a.isMin;   // opens before closes at ties
        return a.index < b.index;                 // deterministic ordering
    });

    active_.clear();
    for (const Endpoint &e : endpoints_) {
        if (e.isMin) {
            for (int other : active_) {
                if (boxes[e.index].overlaps(boxes[other])) {
                    int lo = std::min(e.index, other), hi = std::max(e.index, other);
                    pairs_.emplace_back(lo, hi);
                }
            }
            active_.push_back(e.index);
        } else {
            auto it = std::find(active_.begin(), active_.end(), e.index);
            if (it != active_.end()) active_.erase(it);
        }
    }
    std::sort(pairs_.begin(), pairs_.end());
}

}  // namespace kn
