# Frames, units and conventions

Everything in Kinetic obeys the same small set of rules. Most integration bugs
come from a mismatch here, so they are worth reading once.

## Units

SI, without exception.

| Quantity | Unit |
| --- | --- |
| length | metre |
| mass | kilogram |
| time | second |
| angle | radian |
| force | newton |
| torque | newton-metre |
| density | kg/m³ |

## Axes

**Z is up.** This is the robotics convention and the one URDF and MJCF both use.
Gravity defaults to `(0, 0, −9.81)`.

The renderer, the camera, the axis gizmo and the grid all follow it. The grid's
red line is the X axis, the green line is Y.

## Quaternions

Hamilton convention, stored **(w, x, y, z)**, always unit length.

```swift
let q = Quat(axis: Vec3(0, 0, 1), angle: .pi / 2)
let rotated = q.rotate(Vec3(1, 0, 0))     // ≈ (0, 1, 0)
```

Euler helpers use **roll-pitch-yaw about fixed X, Y, Z** — the convention URDF's
`rpy` attribute uses:

```swift
Quat(roll: 0.1, pitch: -0.2, yaw: 1.5)
```

## Transforms

`Pose` maps a point from a local frame into its parent: `rotation * p + position`.

```swift
let pose = Pose(position: Vec3(1, 0, 0), orientation: q)
pose.apply(Vec3(0, 0, 1))          // local point → parent frame
pose.applyInverse(worldPoint)      // parent frame → local
let composed = parentPose * childPose
```

## State layout

There is one flat state vector per quantity for the entire world. An articulation
occupies a contiguous block, found with `coordinateOffset(articulation:)` and
`dofOffset(articulation:)`.

Position coordinates (`nq`) and velocity coordinates (`nv`) differ, because
rotations are stored as quaternions but their velocities are angular vectors:

| Joint | `nq` | `nv` | `qpos` layout | `qvel` layout |
| --- | --- | --- | --- | --- |
| fixed | 0 | 0 | — | — |
| revolute | 1 | 1 | angle | angular rate |
| prismatic | 1 | 1 | displacement | rate |
| spherical | 4 | 3 | quaternion (w,x,y,z) | angular velocity |
| free | 7 | 6 | position (3), quaternion (4) | linear (3), angular (3) |

This is why you integrate with `world.step()` rather than adding `qvel * dt` to
`qpos` yourself — the quaternion parts need an exponential-map update.

```swift
let q = world.coordinateOffset(articulation: robot)
world.positions[q + 0] = 0.3       // first scalar coordinate of that articulation
```

## Link frames sit at the joint

A link's frame coincides with its joint frame when the joint is at zero. Geometry
attached to the link is positioned by `GeomSpec.localPose` relative to that
frame.

This matters when importing MJCF, which places the body frame at `body/@pos` and
expresses the joint anchor *inside* it. The importer shifts every geom, inertial
and child body by the anchor offset so the two conventions describe the same
mechanism. URDF already matches Kinetic's convention.

## Inertia

`setInertial` takes the mass, the centre of mass **in the link frame**, and the
inertia tensor **about the centre of mass, in link-frame axes**, row-major:

```swift
world.setInertial(articulation: art, link: link,
                  mass: 2.4,
                  com: Vec3(0, 0, -0.12),
                  inertia: [ixx, ixy, ixz,
                            ixy, iyy, iyz,
                            ixz, iyz, izz])
```

If a URDF's `<inertial>` block has a rotated `<origin>`, the importer rotates the
tensor into the link frame with `R I Rᵀ` for you.

The `Inertia` helpers cover the primitives:

```swift
Inertia.box(mass: 1, halfExtents: Vec3(0.1, 0.2, 0.05))
Inertia.sphere(mass: 1, radius: 0.1)
Inertia.capsule(mass: 1, radius: 0.03, length: 0.4)
Inertia.cylinder(mass: 1, radius: 0.05, length: 0.3)
```

Or let the shape derive it from a density:

```swift
world.setInertial(articulation: art, link: link, shape: shape, density: 1200)
```

## Shape parameters

Sizes are **half-extents**, matching MJCF (and unlike URDF's `<box size>`, which
the importer halves for you).

| Shape | Parameters |
| --- | --- |
| `.sphere(radius:)` | radius |
| `.box(halfExtents:)` | half-extents on each axis |
| `.capsule(radius:halfLength:)` | +Z aligned; total length is `2·halfLength + 2·radius` |
| `.cylinder(radius:halfLength:)` | +Z aligned; total length is `2·halfLength` |
| `.plane(extent:)` | infinite +Z half-space; `extent` only affects rendering |
| `.convexHull(mesh:boundingRadius:)` | index into the world's mesh table |

## Contact sign convention

A contact's `normal` points **from geom B toward geom A**, and `depth` is
positive when the shapes overlap. Applying `+normal` to A and `−normal` to B
separates them. `Contact.force` is the force applied to A.
