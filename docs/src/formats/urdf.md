# URDF

```swift
let (world, robot) = try URDF.load(contentsOf: url)
```

The importer covers the parts of URDF that describe physics: links, inertials,
joints with limits and dynamics, visual and collision geometry, materials, and
meshes.

## What maps to what

| URDF | Kinetic |
| --- | --- |
| `<robot name>` | one articulation |
| `<link>` | a link |
| `<joint type="revolute">` | `.revolute`, limited |
| `<joint type="continuous">` | `.revolute`, unlimited |
| `<joint type="prismatic">` | `.prismatic` |
| `<joint type="fixed">` | `.fixed` |
| `<joint type="floating">` | `.free` |
| `<joint type="planar">` | `.fixed`, with a warning — not representable as one joint |
| `<inertial>` | mass, com, inertia tensor |
| `<visual>` | a geom with `collidable = false` |
| `<collision>` | a geom with `visible = false` |
| `<limit lower upper effort velocity>` | joint limits, effort limit, velocity limit |
| `<dynamics damping friction>` | joint damping and dry friction |
| `<material><color rgba>` | appearance |

The root link — the one that is never a child — gets a free joint by default, so
an imported robot floats. Set `fixedBase` to bolt it down.

## Options

```swift
var options = URDFImportOptions()
options.fixedBase = true                       // no floating base
options.packageRoots = [URL(fileURLWithPath: "~/ros_ws/src")]
options.selfCollision = false
options.defaultJointDamping = 0.1              // when <dynamics> is absent
options.defaultArmature = 0.01
options.addPositionActuators = true            // one per movable joint
options.actuatorGainP = 400
options.actuatorGainD = 20
options.onWarning = { print("urdf: \($0)") }

let (world, robot) = try URDF.load(contentsOf: url, options: options)
```

`defaultArmature` is deliberately non-zero. URDF has no way to express rotor
inertia, and real geared joints have a lot of it; without any, high-gain position
control on a light link is needlessly stiff to integrate.

## Geometry

`<box size="a b c">` is a full extent, so the importer halves it — Kinetic's
`.box` takes half-extents. Cylinders and spheres map directly.

`<mesh filename="...">` is resolved and loaded. Collision meshes become convex
hulls; visual meshes keep their triangles. See [Meshes](./meshes.md).

If a link declares only `<visual>` geometry, those shapes are used for collision
too — a common shape for URDFs authored for RViz.

## Inertial frames

`<inertial><origin xyz rpy>` positions the centre of mass *and* orients the
inertia tensor. When `rpy` is non-zero the importer rotates the tensor into the
link frame with \\(R I R^{\\mathsf T}\\); the trace is preserved and principal
moments permute as expected. This is verified in the test suite.

Links with no `<inertial>` get `defaultLinkMass` and an inertia derived from
their collision shape, which keeps the mass matrix positive definite.

## Actuators

With `addPositionActuators` on (the default) each revolute or prismatic joint
gets a position actuator named after the joint, with its control range set to the
joint limits and its force range to `<limit effort>`.

```swift
if let i = world.findActuator("shoulder_pan_joint") {
    world.control[i] = 0.4
}
```

Set it to `false` and drive `world.appliedGeneralizedForces` yourself for torque
control.

## Not handled

- `<transmission>` and `<gazebo>` blocks are ignored.
- `<mimic>` joints are ignored; the joint moves independently.
- Xacro is not expanded — run `xacro` first.
- `planar` joints become fixed.
- Kinematic loops closed by a joint are not representable in a tree; use
  `world.connect` after import.

## Checking an import

```bash
kinetic info myrobot.urdf
```

prints the link tree with joint kinds, masses and limits. In Studio, the
**Joints** tab gives one slider per joint so you can drag each one and confirm
the axis and limits are what you intended — usually faster than reading the XML.
