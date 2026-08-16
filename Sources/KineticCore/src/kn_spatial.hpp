// kn_spatial.hpp — 6D spatial (Plücker) algebra, Featherstone conventions.
//
// Convention used throughout Kinetic:
//   * All spatial quantities are expressed in the WORLD frame with the origin
//     at the world origin. This makes contact Jacobians trivial to assemble and
//     keeps the renderer/solver/sensor code free of frame-conversion bugs.
//   * Motion vectors are ordered [angular; linear], where the linear part is the
//     velocity of the body-fixed point instantaneously coincident with the
//     world origin:  v_O = v_P - omega x p_P.
//   * Force vectors are ordered [torque-about-origin; force].
//
// With that convention a point velocity is  v_P = v_O + omega x p_P, and a
// revolute joint at world point p with world axis a has motion subspace
// S = [a; p x a].
#pragma once

#include "kn_math.hpp"

namespace kn {

// Spatial motion vector: [angular; linear].
struct SpatialVec {
    Vec3 ang = Vec3::zero();
    Vec3 lin = Vec3::zero();

    constexpr SpatialVec() = default;
    SpatialVec(const Vec3 &a, const Vec3 &l) : ang(a), lin(l) {}

    static SpatialVec zero() { return {}; }

    SpatialVec operator+(const SpatialVec &o) const { return {ang + o.ang, lin + o.lin}; }
    SpatialVec operator-(const SpatialVec &o) const { return {ang - o.ang, lin - o.lin}; }
    SpatialVec operator*(Scalar s) const { return {ang * s, lin * s}; }
    SpatialVec operator-() const { return {-ang, -lin}; }
    SpatialVec &operator+=(const SpatialVec &o) { ang += o.ang; lin += o.lin; return *this; }
    SpatialVec &operator-=(const SpatialVec &o) { ang -= o.ang; lin -= o.lin; return *this; }

    Scalar dot(const SpatialVec &f) const { return ang.dot(f.ang) + lin.dot(f.lin); }

    // Velocity of the body-fixed point currently at world position p.
    Vec3 pointVelocity(const Vec3 &p) const { return lin + ang.cross(p); }

    bool isFinite() const { return ang.isFinite() && lin.isFinite(); }
};

inline SpatialVec operator*(Scalar s, const SpatialVec &v) { return v * s; }

// Motion cross product:  crm(v) * m.
inline SpatialVec crossMotion(const SpatialVec &v, const SpatialVec &m) {
    return {v.ang.cross(m.ang), v.ang.cross(m.lin) + v.lin.cross(m.ang)};
}

// Force cross product:  crf(v) * f  ==  -crm(v)^T * f.
inline SpatialVec crossForce(const SpatialVec &v, const SpatialVec &f) {
    return {v.ang.cross(f.ang) + v.lin.cross(f.lin), v.ang.cross(f.lin)};
}

// ─────────────────────────────────────────────────── SpatialInertia ──

// Rigid-body inertia about the world origin, expressed in world axes:
//
//   [ I_c - m [c]x [c]x   m [c]x ]
//   [       -m [c]x        m 1   ]
//
// stored as (mass, h = m*c, rotational block).
struct SpatialInertia {
    Scalar mass = 0;
    Vec3 h = Vec3::zero();     // m * c, with c the world-space centre of mass
    Mat3 I = Mat3::zero();     // rotational block about the world origin

    static SpatialInertia zero() { return {}; }

    // Builds the world-frame spatial inertia of a body whose centre of mass is
    // at world point `com` and whose rotational inertia about the com, rotated
    // into world axes, is `Icom`.
    static SpatialInertia fromComInertia(Scalar mass, const Vec3 &com, const Mat3 &Icom) {
        SpatialInertia si;
        si.mass = mass;
        si.h = com * mass;
        Mat3 cx = Mat3::skew(com);
        si.I = Icom - (cx * cx) * mass;  // parallel-axis transfer to the origin
        return si;
    }

    SpatialVec operator*(const SpatialVec &v) const {
        Mat3 hx = Mat3::skew(h);
        return {I * v.ang + hx * v.lin, v.lin * mass - hx * v.ang};
    }

    SpatialInertia operator+(const SpatialInertia &o) const {
        SpatialInertia r;
        r.mass = mass + o.mass;
        r.h = h + o.h;
        r.I = I + o.I;
        return r;
    }
    SpatialInertia &operator+=(const SpatialInertia &o) {
        mass += o.mass;
        h += o.h;
        I = I + o.I;
        return *this;
    }
};

// Rotates a com-frame inertia tensor into world axes: R * I * R^T.
inline Mat3 rotateInertia(const Mat3 &R, const Mat3 &Ilocal) {
    return R * Ilocal * R.transposed();
}

// Inertia tensors of the analytic primitives, about the centre of mass.
inline Mat3 inertiaSphere(Scalar mass, Scalar r) {
    Scalar v = Scalar(0.4) * mass * r * r;
    return Mat3::diagonal({v, v, v});
}

inline Mat3 inertiaBox(Scalar mass, const Vec3 &halfExtents) {
    Vec3 s = halfExtents * 2;
    Scalar k = mass / Scalar(12);
    return Mat3::diagonal({k * (s.y * s.y + s.z * s.z), k * (s.x * s.x + s.z * s.z),
                           k * (s.x * s.x + s.y * s.y)});
}

// Capsule aligned with +Z: cylinder of length `h` capped by hemispheres of
// radius `r`, with the mass split by volume between the parts.
inline Mat3 inertiaCapsule(Scalar mass, Scalar r, Scalar h) {
    Scalar vc = kPi * r * r * h;
    Scalar vs = Scalar(4.0 / 3.0) * kPi * r * r * r;
    Scalar total = vc + vs;
    if (total < kEps) return Mat3::zero();
    Scalar mc = mass * vc / total;
    Scalar ms = mass * vs / total;

    Scalar izz = Scalar(0.5) * mc * r * r + Scalar(0.4) * ms * r * r;
    Scalar ixx = mc * (Scalar(3) * r * r + h * h) / Scalar(12) +
                 ms * (Scalar(0.4) * r * r + Scalar(0.375) * r * h + Scalar(0.25) * h * h);
    return Mat3::diagonal({ixx, ixx, izz});
}

inline Mat3 inertiaCylinder(Scalar mass, Scalar r, Scalar h) {
    Scalar izz = Scalar(0.5) * mass * r * r;
    Scalar ixx = mass * (Scalar(3) * r * r + h * h) / Scalar(12);
    return Mat3::diagonal({ixx, ixx, izz});
}

}  // namespace kn
