# Building a model

A world is a set of **articulations**. An articulation is a kinematic tree of
**links**, each attached to its parent by a **joint**. A free-floating rigid body
is just an articulation with one link and a free joint, so the solver only ever
sees one kind of object.

## The shortest path

For single-body props, use the convenience builders:

```swift
let world = World()

world.addGround(friction: 1.0)

world.addRigidBody(name: "crate",
                   shape: .box(halfExtents: Vec3(0.15, 0.15, 0.15)),
                   density: 400,
                   pose: Pose(position: Vec3(0, 0, 1)),
                   material: .rubber,
                   appearance: .solid(0.9, 0.4, 0.2))

world.addStaticBody(name: "ramp",
                    shape: .box(halfExtents: Vec3(1, 0.5, 0.02)),
                    pose: Pose(position: Vec3(2, 0, 0.3),
                               orientation: Quat(axis: Vec3(0, 1, 0), angle: -0.3)))

world.compile()
```

`addStaticBody` creates an articulation with zero degrees of freedom. Static
geometry costs nothing in the solver: pairs where both sides are static are
filtered out before narrowphase.

## Building a tree by hand

```swift
let robot = world.addArticulation(name: "robot")

let base = world.addLink(articulation: robot, parent: -1, name: "base")
world.setJoint(articulation: robot, link: base, .fixed)      // bolted down
world.setInertial(articulation: robot, link: base, shape: baseShape, density: 2700)
world.addGeom(articulation: robot, link: base, GeomSpec(shape: baseShape))

let shoulder = world.addLink(articulation: robot, parent: base, name: "shoulder")
world.setJoint(articulation: robot, link: shoulder,
               JointSpec.revolute(axis: Vec3(0, 1, 0),
                                  origin: Pose(position: Vec3(0, 0, 0.12)),
                                  limits: -1.9...1.9,
                                  damping: 2.0,
                                  armature: 0.02))
```

Rules:

- **`parent: -1` means the world.** A link with parent −1 and a `.fixed` joint is
  bolted in place; with a `.free` joint it floats.
- **Add parents before children.** `addLink` returns the index you pass as the
  next link's parent, so natural construction order already satisfies this.
- **A link frame sits at its joint.** `JointSpec.origin` maps the parent's link
  frame to this joint's frame at zero.

## Joints

| Kind | dof | Use |
| --- | --- | --- |
| `.fixed` | 0 | rigid attachment; still a separate link for geometry and sensors |
| `.revolute` | 1 | hinge about `axis` |
| `.prismatic` | 1 | slide along `axis` |
| `.spherical` | 3 | ball joint |
| `.free` | 6 | floating base |

```swift
JointSpec.revolute(axis: Vec3(0, 0, 1),
                   origin: Pose(position: Vec3(0, 0, 0.1)),
                   limits: -2.9...2.9,
                   damping: 1.5,
                   armature: 0.01)
```

Other fields worth knowing:

| Field | Effect |
| --- | --- |
| `armature` | rotor inertia added to the diagonal of M — improves conditioning |
| `damping` | viscous, integrated implicitly, unconditionally stable |
| `friction` | dry Coulomb friction, solved as a bounded constraint |
| `stiffness` / `springReference` | linear spring toward a rest position |
| `effortLimit` | clamps actuator output on that joint |

> Free joints must be roots with an identity origin. A free joint deeper in a
> tree is not a meaningful construct — use a spherical joint plus prismatic
> joints, or a second articulation joined by an equality constraint.

## Geometry

One link can carry many geoms. Each has its own pose, material and appearance.

```swift
world.addGeom(articulation: robot, link: shank,
              GeomSpec(shape: .capsule(radius: 0.02, halfLength: 0.08),
                       localPose: Pose(position: Vec3(0, 0, -0.08)),
                       material: SurfaceMaterial(friction: 1.3),
                       appearance: Appearance(color: Vec4(0.2, 0.2, 0.24, 1),
                                              metallic: 0.3, roughness: 0.4),
                       collidable: true,
                       visible: true,
                       name: "shank"))
```

`collidable` and `visible` are independent, which is how you carry a detailed
visual mesh alongside a cheap collision proxy — the usual arrangement in a real
robot description.

## Collision filtering

Every geom has a `group` bitmask (what it is) and a `mask` bitmask (what it may
touch). A pair is tested only if both directions agree.

```swift
var sensorVolume = GeomSpec(shape: .sphere(radius: 0.5))
sensorVolume.group = 0b0010
sensorVolume.mask  = 0b0100      // only sees group 3 objects
sensorVolume.visible = false
```

Self-collision within an articulation is off by default and enabled per
articulation. Parent-child pairs are always skipped, since links sharing a joint
necessarily overlap near it.

```swift
world.setSelfCollision(articulation: robot, enabled: true)
```

## Default pose

`setDefaultPose` supplies the `qpos` block that `reset()` restores. It must match
the articulation's `nq` exactly.

```swift
// free base (3 position + 4 quaternion) then twelve joint angles
world.setDefaultPose(articulation: robot,
                     q: [0, 0, 0.30, 1, 0, 0, 0] + legAngles)
```

For position-controlled robots, also seed `control` after `compile()` — otherwise
the actuators drive every joint to zero and a legged robot collapses on frame
one:

```swift
world.compile()
for (i, angle) in legAngles.enumerated() { world.control[i] = angle }
```

## Equality constraints

For loops the tree cannot express:

```swift
// ball joint between two links
world.connect(articulationA: armA, linkA: tipA, anchorA: Vec3(0, 0, 0.1),
              articulationB: armB, linkB: tipB, anchorB: Vec3(0, 0, 0.1))

// pin a link rigidly to the world
world.weld(articulationA: robot, linkA: base)
```

These are solved alongside contacts, so they are soft in the same physically
parameterised way and can be tuned with the same time constant.

## Compile

`compile()` freezes the model:

- assigns coordinate and dof offsets for every articulation and joint;
- builds child lists and the flat link index;
- resolves actuator target dofs and sensor offsets;
- sizes every cache and state vector;
- resets to the default pose.

Anything that changes topology sets a dirty flag and requires another compile.
Anything that changes *state* — `positions`, `control`, `options`, materials via
the geom table — does not.

> The state buffers are engine memory exposed through
> `UnsafeMutableBufferPointer`. `compile()` reallocates them, so never hold a
> buffer across a compile.
