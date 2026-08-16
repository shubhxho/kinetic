//
//  Math.swift
//  Kinetic
//
//  Value types shared by the simulator, the renderer and the tooling. These map
//  1:1 onto the C ABI's plain-double layout, so bridging is a memcpy in
//  practice.
//

import Foundation
import simd

public typealias Vec3 = SIMD3<Double>
public typealias Vec4 = SIMD4<Double>

extension Vec3 {
    public static let up = Vec3(0, 0, 1)
    public static let forward = Vec3(1, 0, 0)
    public static let left = Vec3(0, 1, 0)

    public var length: Double { simd_length(self) }
    public var normalized: Vec3 {
        let l = simd_length(self)
        return l > 1e-12 ? self / l : .zero
    }
    public func cross(_ other: Vec3) -> Vec3 { simd_cross(self, other) }
    public func dot(_ other: Vec3) -> Double { simd_dot(self, other) }
}

/// Unit quaternion, Hamilton convention, stored `(w, x, y, z)` to match the
/// engine's wire layout.
public struct Quat: Equatable, Hashable, Codable, Sendable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double = 1, x: Double = 0, y: Double = 0, z: Double = 0) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quat()

    public init(axis: Vec3, angle: Double) {
        let a = axis.normalized
        let h = angle * 0.5
        let s = sin(h)
        self.init(w: cos(h), x: a.x * s, y: a.y * s, z: a.z * s)
    }

    /// Roll–pitch–yaw about fixed X, Y, Z axes — the convention URDF uses.
    public init(roll: Double, pitch: Double, yaw: Double) {
        let cr = cos(roll * 0.5), sr = sin(roll * 0.5)
        let cp = cos(pitch * 0.5), sp = sin(pitch * 0.5)
        let cy = cos(yaw * 0.5), sy = sin(yaw * 0.5)
        self.init(
            w: cr * cp * cy + sr * sp * sy,
            x: sr * cp * cy - cr * sp * sy,
            y: cr * sp * cy + sr * cp * sy,
            z: cr * cp * sy - sr * sp * cy)
    }

    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        guard n > 1e-12 else { return .identity }
        return Quat(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    public func rotate(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = 2 * u.cross(v)
        return v + w * t + u.cross(t)
    }

    public func inverseRotate(_ v: Vec3) -> Vec3 { conjugate.rotate(v) }

    /// Roll, pitch and yaw in the same convention as `init(roll:pitch:yaw:)`.
    public var eulerRPY: Vec3 {
        let sinrCosp = 2 * (w * x + y * z)
        let cosrCosp = 1 - 2 * (x * x + y * y)
        let roll = atan2(sinrCosp, cosrCosp)
        let sinp = 2 * (w * y - z * x)
        let pitch = abs(sinp) >= 1 ? copysign(.pi / 2, sinp) : asin(sinp)
        let sinyCosp = 2 * (w * z + x * y)
        let cosyCosp = 1 - 2 * (y * y + z * z)
        let yaw = atan2(sinyCosp, cosyCosp)
        return Vec3(roll, pitch, yaw)
    }

    public var simd: simd_quatd { simd_quatd(ix: x, iy: y, iz: z, r: w) }

    public init(_ q: simd_quatd) {
        self.init(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z)
    }

    public static func slerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        Quat(simd_slerp(a.simd, b.simd, t))
    }
}

/// Rigid transform. Applying it maps a point from the local frame to the parent
/// frame: `rotation * p + position`.
public struct Pose: Equatable, Hashable, Codable, Sendable {
    public var position: Vec3
    public var orientation: Quat

    public init(position: Vec3 = .zero, orientation: Quat = .identity) {
        self.position = position
        self.orientation = orientation
    }

    public static let identity = Pose()

    public func apply(_ p: Vec3) -> Vec3 { orientation.rotate(p) + position }
    public func applyVector(_ v: Vec3) -> Vec3 { orientation.rotate(v) }
    public func applyInverse(_ p: Vec3) -> Vec3 { orientation.inverseRotate(p - position) }

    public static func * (a: Pose, b: Pose) -> Pose {
        Pose(position: a.orientation.rotate(b.position) + a.position,
             orientation: (a.orientation * b.orientation).normalized)
    }

    public var inverse: Pose {
        let r = orientation.conjugate
        return Pose(position: r.rotate(-position), orientation: r)
    }

    /// Column-major 4x4 suitable for handing straight to Metal.
    public var matrix: simd_float4x4 {
        let r = simd_float3x3(simd_quatf(
            ix: Float(orientation.x), iy: Float(orientation.y),
            iz: Float(orientation.z), r: Float(orientation.w)))
        return simd_float4x4(
            SIMD4<Float>(r.columns.0, 0),
            SIMD4<Float>(r.columns.1, 0),
            SIMD4<Float>(r.columns.2, 0),
            SIMD4<Float>(Float(position.x), Float(position.y), Float(position.z), 1))
    }
}

extension Vec3 {
    /// Inertia tensor rows for a diagonal tensor, in the engine's row-major layout.
    public var diagonalInertia: [Double] { [x, 0, 0, 0, y, 0, 0, 0, z] }
}

public enum Inertia {
    public static func sphere(mass: Double, radius: Double) -> [Double] {
        let v = 0.4 * mass * radius * radius
        return Vec3(v, v, v).diagonalInertia
    }

    public static func box(mass: Double, halfExtents h: Vec3) -> [Double] {
        let s = h * 2
        let k = mass / 12
        return Vec3(k * (s.y * s.y + s.z * s.z),
                    k * (s.x * s.x + s.z * s.z),
                    k * (s.x * s.x + s.y * s.y)).diagonalInertia
    }

    public static func cylinder(mass: Double, radius r: Double, length l: Double) -> [Double] {
        let izz = 0.5 * mass * r * r
        let ixx = mass * (3 * r * r + l * l) / 12
        return Vec3(ixx, ixx, izz).diagonalInertia
    }

    public static func capsule(mass: Double, radius r: Double, length l: Double) -> [Double] {
        let vc = Double.pi * r * r * l
        let vs = 4.0 / 3.0 * Double.pi * r * r * r
        let total = vc + vs
        guard total > 1e-12 else { return Vec3.zero.diagonalInertia }
        let mc = mass * vc / total
        let ms = mass * vs / total
        let izz = 0.5 * mc * r * r + 0.4 * ms * r * r
        let ixx = mc * (3 * r * r + l * l) / 12 + ms * (0.4 * r * r + 0.375 * r * l + 0.25 * l * l)
        return Vec3(ixx, ixx, izz).diagonalInertia
    }
}
