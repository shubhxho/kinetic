//
//  Camera.swift
//  KineticRender
//
//  Orbit camera and the small set of matrix helpers the renderer needs. Kinetic
//  is Z-up (the robotics convention), so the camera math here is written for a
//  Z-up world and a Metal clip space with depth in [0, 1].
//

import Foundation
import simd

public enum Matrix {
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float)
        -> simd_float4x4
    {
        let y = 1 / tan(fovY * 0.5)
        let x = y / max(aspect, 1e-5)
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0))
    }

    public static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                                    near: Float, far: Float) -> simd_float4x4 {
        let rsl = right - left, tsb = top - bottom, fsn = far - near
        return simd_float4x4(
            SIMD4<Float>(2 / rsl, 0, 0, 0),
            SIMD4<Float>(0, 2 / tsb, 0, 0),
            SIMD4<Float>(0, 0, -1 / fsn, 0),
            SIMD4<Float>(-(right + left) / rsl, -(top + bottom) / tsb, -near / fsn, 1))
    }

    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>)
        -> simd_float4x4
    {
        let f = simd_normalize(target - eye)
        var upVector = up
        if abs(simd_dot(f, simd_normalize(up))) > 0.999 { upVector = SIMD3<Float>(0, 1, 0) }
        let s = simd_normalize(simd_cross(f, upVector))
        let u = simd_cross(s, f)
        return simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
    }

    public static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }

    public static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
    }
}

public struct OrbitCamera {
    /// Point the camera orbits, in world space.
    public var target = SIMD3<Float>(0, 0, 0.4)
    public var distance: Float = 3.2
    /// Rotation about the world Z axis, radians.
    public var azimuth: Float = -0.9
    /// Angle above the XY plane, radians, clamped away from the poles.
    public var elevation: Float = 0.42
    public var fieldOfView: Float = 50 * .pi / 180
    public var near: Float = 0.02
    public var far: Float = 400

    public init() {}

    public var position: SIMD3<Float> {
        let cosE = cos(elevation)
        return target + SIMD3<Float>(cos(azimuth) * cosE, sin(azimuth) * cosE, sin(elevation))
            * distance
    }

    public var viewMatrix: simd_float4x4 {
        Matrix.lookAt(eye: position, target: target, up: SIMD3<Float>(0, 0, 1))
    }

    public func projectionMatrix(aspect: Float) -> simd_float4x4 {
        Matrix.perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far)
    }

    public mutating func orbit(deltaX: Float, deltaY: Float) {
        azimuth -= deltaX
        elevation = max(-1.52, min(1.52, elevation + deltaY))
    }

    public mutating func pan(deltaX: Float, deltaY: Float) {
        let forward = simd_normalize(target - position)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 0, 1)))
        let up = simd_cross(right, forward)
        let scale = distance * 0.0016
        target += (-right * deltaX + up * deltaY) * scale
    }

    public mutating func zoom(_ delta: Float) {
        distance = max(0.15, min(220, distance * exp(-delta * 0.12)))
    }

    /// Frames an axis-aligned bounding box with a little breathing room.
    public mutating func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>) {
        let center = (lo + hi) * 0.5
        let radius = max(simd_length(hi - lo) * 0.5, 0.25)
        target = center
        distance = radius / tan(fieldOfView * 0.5) * 1.12
    }
}
