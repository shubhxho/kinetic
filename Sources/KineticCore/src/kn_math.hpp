// kn_math.hpp — vector / quaternion / matrix primitives and dense linear algebra.
//
// Everything the dynamics pipeline needs, in double precision. Determinism is a
// hard requirement (identical inputs must produce bit-identical outputs across
// runs on the same binary), so no fast-math reassociation and no threaded
// reductions live in here.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace kn {

using Scalar = double;

inline constexpr Scalar kPi = 3.14159265358979323846;
inline constexpr Scalar kEps = 1e-12;

inline Scalar clampf(Scalar v, Scalar lo, Scalar hi) { return v < lo ? lo : (v > hi ? hi : v); }

// ─────────────────────────────────────────────────────────────── Vec3 ──

struct Vec3 {
    Scalar x = 0, y = 0, z = 0;

    constexpr Vec3() = default;
    constexpr Vec3(Scalar x_, Scalar y_, Scalar z_) : x(x_), y(y_), z(z_) {}

    static constexpr Vec3 zero() { return {0, 0, 0}; }
    static constexpr Vec3 unitX() { return {1, 0, 0}; }
    static constexpr Vec3 unitY() { return {0, 1, 0}; }
    static constexpr Vec3 unitZ() { return {0, 0, 1}; }

    Scalar &operator[](int i) { return (&x)[i]; }
    Scalar operator[](int i) const { return (&x)[i]; }

    Vec3 operator+(const Vec3 &o) const { return {x + o.x, y + o.y, z + o.z}; }
    Vec3 operator-(const Vec3 &o) const { return {x - o.x, y - o.y, z - o.z}; }
    Vec3 operator-() const { return {-x, -y, -z}; }
    Vec3 operator*(Scalar s) const { return {x * s, y * s, z * s}; }
    Vec3 operator/(Scalar s) const { return {x / s, y / s, z / s}; }
    Vec3 &operator+=(const Vec3 &o) { x += o.x; y += o.y; z += o.z; return *this; }
    Vec3 &operator-=(const Vec3 &o) { x -= o.x; y -= o.y; z -= o.z; return *this; }
    Vec3 &operator*=(Scalar s) { x *= s; y *= s; z *= s; return *this; }

    Scalar dot(const Vec3 &o) const { return x * o.x + y * o.y + z * o.z; }
    Vec3 cross(const Vec3 &o) const {
        return {y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x};
    }
    Scalar normSquared() const { return x * x + y * y + z * z; }
    Scalar norm() const { return std::sqrt(normSquared()); }
    Vec3 normalized() const {
        Scalar n = norm();
        return n > kEps ? *this / n : Vec3{0, 0, 0};
    }
    Vec3 cwiseMul(const Vec3 &o) const { return {x * o.x, y * o.y, z * o.z}; }
    Scalar maxCoeff() const { return std::max(x, std::max(y, z)); }
    Scalar minCoeff() const { return std::min(x, std::min(y, z)); }
    bool isFinite() const { return std::isfinite(x) && std::isfinite(y) && std::isfinite(z); }
};

inline Vec3 operator*(Scalar s, const Vec3 &v) { return v * s; }

// Builds an arbitrary orthonormal basis around `n` (Duff et al., branchless).
inline void orthoBasis(const Vec3 &n, Vec3 &t1, Vec3 &t2) {
    Scalar sign = std::copysign(Scalar(1), n.z);
    Scalar a = Scalar(-1) / (sign + n.z);
    Scalar b = n.x * n.y * a;
    t1 = Vec3(1 + sign * n.x * n.x * a, sign * b, -sign * n.x);
    t2 = Vec3(b, sign + n.y * n.y * a, -n.y);
}

// ─────────────────────────────────────────────────────────────── Mat3 ──

// Row-major 3x3.
struct Mat3 {
    Scalar m[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};

    constexpr Mat3() = default;
    constexpr Mat3(Scalar a, Scalar b, Scalar c, Scalar d, Scalar e, Scalar f, Scalar g, Scalar h,
                   Scalar i)
        : m{a, b, c, d, e, f, g, h, i} {}

    static constexpr Mat3 identity() { return {}; }
    static constexpr Mat3 zero() { return {0, 0, 0, 0, 0, 0, 0, 0, 0}; }
    static Mat3 diagonal(const Vec3 &d) { return {d.x, 0, 0, 0, d.y, 0, 0, 0, d.z}; }

    // Skew-symmetric matrix such that skew(a) * b == a.cross(b).
    static Mat3 skew(const Vec3 &a) { return {0, -a.z, a.y, a.z, 0, -a.x, -a.y, a.x, 0}; }

    Scalar &operator()(int r, int c) { return m[r * 3 + c]; }
    Scalar operator()(int r, int c) const { return m[r * 3 + c]; }

    Vec3 row(int r) const { return {m[r * 3], m[r * 3 + 1], m[r * 3 + 2]}; }
    Vec3 col(int c) const { return {m[c], m[3 + c], m[6 + c]}; }

    Vec3 operator*(const Vec3 &v) const {
        return {m[0] * v.x + m[1] * v.y + m[2] * v.z, m[3] * v.x + m[4] * v.y + m[5] * v.z,
                m[6] * v.x + m[7] * v.y + m[8] * v.z};
    }
    Mat3 operator*(const Mat3 &o) const {
        Mat3 r;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                r.m[i * 3 + j] = m[i * 3] * o.m[j] + m[i * 3 + 1] * o.m[3 + j] +
                                 m[i * 3 + 2] * o.m[6 + j];
        return r;
    }
    Mat3 operator*(Scalar s) const {
        Mat3 r;
        for (int i = 0; i < 9; ++i) r.m[i] = m[i] * s;
        return r;
    }
    Mat3 operator+(const Mat3 &o) const {
        Mat3 r;
        for (int i = 0; i < 9; ++i) r.m[i] = m[i] + o.m[i];
        return r;
    }
    Mat3 operator-(const Mat3 &o) const {
        Mat3 r;
        for (int i = 0; i < 9; ++i) r.m[i] = m[i] - o.m[i];
        return r;
    }
    Mat3 &operator+=(const Mat3 &o) {
        for (int i = 0; i < 9; ++i) m[i] += o.m[i];
        return *this;
    }
    Mat3 transposed() const {
        return {m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]};
    }
    Scalar trace() const { return m[0] + m[4] + m[8]; }
    Scalar determinant() const {
        return m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) +
               m[2] * (m[3] * m[7] - m[4] * m[6]);
    }
    Mat3 inverse() const {
        Scalar det = determinant();
        if (std::abs(det) < 1e-18) return Mat3::zero();
        Scalar id = Scalar(1) / det;
        Mat3 r;
        r.m[0] = (m[4] * m[8] - m[5] * m[7]) * id;
        r.m[1] = (m[2] * m[7] - m[1] * m[8]) * id;
        r.m[2] = (m[1] * m[5] - m[2] * m[4]) * id;
        r.m[3] = (m[5] * m[6] - m[3] * m[8]) * id;
        r.m[4] = (m[0] * m[8] - m[2] * m[6]) * id;
        r.m[5] = (m[2] * m[3] - m[0] * m[5]) * id;
        r.m[6] = (m[3] * m[7] - m[4] * m[6]) * id;
        r.m[7] = (m[1] * m[6] - m[0] * m[7]) * id;
        r.m[8] = (m[0] * m[4] - m[1] * m[3]) * id;
        return r;
    }
};

// ─────────────────────────────────────────────────────────────── Quat ──

// Hamilton convention, (w, x, y, z), unit-norm rotations.
struct Quat {
    Scalar w = 1, x = 0, y = 0, z = 0;

    constexpr Quat() = default;
    constexpr Quat(Scalar w_, Scalar x_, Scalar y_, Scalar z_) : w(w_), x(x_), y(y_), z(z_) {}

    static constexpr Quat identity() { return {}; }

    static Quat fromAxisAngle(const Vec3 &axis, Scalar angle) {
        Vec3 a = axis.normalized();
        Scalar h = angle * Scalar(0.5);
        Scalar s = std::sin(h);
        return {std::cos(h), a.x * s, a.y * s, a.z * s};
    }

    // Exponential map of a rotation vector (angle * axis).
    static Quat fromRotationVector(const Vec3 &r) {
        Scalar theta = r.norm();
        if (theta < 1e-9) {
            Quat q(1, r.x * Scalar(0.5), r.y * Scalar(0.5), r.z * Scalar(0.5));
            return q.normalized();
        }
        return fromAxisAngle(r / theta, theta);
    }

    static Quat fromEulerRPY(Scalar roll, Scalar pitch, Scalar yaw) {
        Scalar cr = std::cos(roll * .5), sr = std::sin(roll * .5);
        Scalar cp = std::cos(pitch * .5), sp = std::sin(pitch * .5);
        Scalar cy = std::cos(yaw * .5), sy = std::sin(yaw * .5);
        return {cr * cp * cy + sr * sp * sy, sr * cp * cy - cr * sp * sy,
                cr * sp * cy + sr * cp * sy, cr * cp * sy - sr * sp * cy};
    }

    static Quat fromMatrix(const Mat3 &R) {
        Scalar tr = R.trace();
        Quat q;
        if (tr > 0) {
            Scalar s = std::sqrt(tr + 1) * 2;
            q.w = Scalar(0.25) * s;
            q.x = (R(2, 1) - R(1, 2)) / s;
            q.y = (R(0, 2) - R(2, 0)) / s;
            q.z = (R(1, 0) - R(0, 1)) / s;
        } else if (R(0, 0) > R(1, 1) && R(0, 0) > R(2, 2)) {
            Scalar s = std::sqrt(1 + R(0, 0) - R(1, 1) - R(2, 2)) * 2;
            q.w = (R(2, 1) - R(1, 2)) / s;
            q.x = Scalar(0.25) * s;
            q.y = (R(0, 1) + R(1, 0)) / s;
            q.z = (R(0, 2) + R(2, 0)) / s;
        } else if (R(1, 1) > R(2, 2)) {
            Scalar s = std::sqrt(1 + R(1, 1) - R(0, 0) - R(2, 2)) * 2;
            q.w = (R(0, 2) - R(2, 0)) / s;
            q.x = (R(0, 1) + R(1, 0)) / s;
            q.y = Scalar(0.25) * s;
            q.z = (R(1, 2) + R(2, 1)) / s;
        } else {
            Scalar s = std::sqrt(1 + R(2, 2) - R(0, 0) - R(1, 1)) * 2;
            q.w = (R(1, 0) - R(0, 1)) / s;
            q.x = (R(0, 2) + R(2, 0)) / s;
            q.y = (R(1, 2) + R(2, 1)) / s;
            q.z = Scalar(0.25) * s;
        }
        return q.normalized();
    }

    Quat operator*(const Quat &o) const {
        return {w * o.w - x * o.x - y * o.y - z * o.z, w * o.x + x * o.w + y * o.z - z * o.y,
                w * o.y - x * o.z + y * o.w + z * o.x, w * o.z + x * o.y - y * o.x + z * o.w};
    }
    Quat conjugate() const { return {w, -x, -y, -z}; }
    Scalar norm() const { return std::sqrt(w * w + x * x + y * y + z * z); }
    Quat normalized() const {
        Scalar n = norm();
        if (n < kEps) return identity();
        return {w / n, x / n, y / n, z / n};
    }
    void normalize() { *this = normalized(); }

    Vec3 rotate(const Vec3 &v) const {
        Vec3 u(x, y, z);
        Vec3 t = u.cross(v) * 2;
        return v + t * w + u.cross(t);
    }
    Vec3 inverseRotate(const Vec3 &v) const { return conjugate().rotate(v); }

    Mat3 toMatrix() const {
        Scalar xx = x * x, yy = y * y, zz = z * z;
        Scalar xy = x * y, xz = x * z, yz = y * z;
        Scalar wx = w * x, wy = w * y, wz = w * z;
        return {1 - 2 * (yy + zz), 2 * (xy - wz),     2 * (xz + wy),
                2 * (xy + wz),     1 - 2 * (xx + zz), 2 * (yz - wx),
                2 * (xz - wy),     2 * (yz + wx),     1 - 2 * (xx + yy)};
    }

    // Rotation vector such that fromRotationVector(v) == *this (shortest path).
    Vec3 toRotationVector() const {
        Quat q = (w < 0) ? Quat(-w, -x, -y, -z) : *this;
        Scalar s = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
        if (s < 1e-9) return Vec3(q.x, q.y, q.z) * 2;
        Scalar angle = 2 * std::atan2(s, q.w);
        return Vec3(q.x, q.y, q.z) * (angle / s);
    }
};

// ────────────────────────────────────────────────────────── Transform ──

// Rigid transform: maps a point in the local frame to the parent frame as
// `rot * p + pos`.
struct Transform {
    Quat rot = Quat::identity();
    Vec3 pos = Vec3::zero();

    constexpr Transform() = default;
    Transform(const Quat &r, const Vec3 &p) : rot(r), pos(p) {}

    static Transform identity() { return {}; }

    Vec3 apply(const Vec3 &p) const { return rot.rotate(p) + pos; }
    Vec3 applyInverse(const Vec3 &p) const { return rot.inverseRotate(p - pos); }
    Vec3 applyVector(const Vec3 &v) const { return rot.rotate(v); }

    Transform operator*(const Transform &o) const {
        return {(rot * o.rot).normalized(), rot.rotate(o.pos) + pos};
    }
    Transform inverse() const {
        Quat ri = rot.conjugate();
        return {ri, ri.rotate(-pos)};
    }
};

// ─────────────────────────────────────────── dense vectors / matrices ──

using VecX = std::vector<Scalar>;

// Row-major dense matrix used for the joint-space inertia and the Delassus
// operator. Sizes are small (nv is tens, not thousands) so a plain dense
// representation with an LDL^T factorisation is the right call.
struct MatX {
    int rows = 0, cols = 0;
    std::vector<Scalar> d;

    MatX() = default;
    MatX(int r, int c) : rows(r), cols(c), d(std::size_t(r) * c, 0) {}

    void resize(int r, int c) {
        rows = r;
        cols = c;
        d.assign(std::size_t(r) * c, 0);
    }
    void setZero() { std::fill(d.begin(), d.end(), Scalar(0)); }

    Scalar &operator()(int r, int c) { return d[std::size_t(r) * cols + c]; }
    Scalar operator()(int r, int c) const { return d[std::size_t(r) * cols + c]; }
};

// In-place LDL^T factorisation of a symmetric positive-definite matrix.
// Returns false if the matrix is not usably positive definite; callers fall
// back to a diagonal-regularised retry rather than propagating NaNs.
inline bool ldltFactor(MatX &A, Scalar regularization = 1e-10) {
    const int n = A.rows;
    for (int j = 0; j < n; ++j) {
        Scalar sum = A(j, j);
        for (int k = 0; k < j; ++k) sum -= A(j, k) * A(j, k) * A(k, k);
        if (sum < regularization) {
            if (sum < -1e-6) return false;
            sum = regularization;
        }
        A(j, j) = sum;
        Scalar inv = Scalar(1) / sum;
        for (int i = j + 1; i < n; ++i) {
            Scalar s = A(i, j);
            for (int k = 0; k < j; ++k) s -= A(i, k) * A(j, k) * A(k, k);
            A(i, j) = s * inv;
        }
    }
    return true;
}

// Solves A x = b in place, where A holds the LDL^T factors from ldltFactor.
inline void ldltSolveInPlace(const MatX &LD, Scalar *x, int stride = 1) {
    const int n = LD.rows;
    for (int i = 0; i < n; ++i) {
        Scalar s = x[i * stride];
        for (int k = 0; k < i; ++k) s -= LD(i, k) * x[k * stride];
        x[i * stride] = s;
    }
    for (int i = 0; i < n; ++i) x[i * stride] /= LD(i, i);
    for (int i = n - 1; i >= 0; --i) {
        Scalar s = x[i * stride];
        for (int k = i + 1; k < n; ++k) s -= LD(k, i) * x[k * stride];
        x[i * stride] = s;
    }
}

// Symmetric 3x3 solve used per-contact; falls back to a regularised inverse.
inline Vec3 solve3x3(const Mat3 &A, const Vec3 &b, Scalar reg = 1e-10) {
    Mat3 M = A;
    M(0, 0) += reg;
    M(1, 1) += reg;
    M(2, 2) += reg;
    return M.inverse() * b;
}

}  // namespace kn
