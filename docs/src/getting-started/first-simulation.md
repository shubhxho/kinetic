# Your first simulation

## A ball on the floor

```swift
import Kinetic

let world = World()
world.addGround(friction: 1.0)
world.addRigidBody(
    name: "ball",
    shape: .sphere(radius: 0.2),
    density: 500,
    pose: Pose(position: Vec3(0, 0, 1)),
    material: SurfaceMaterial(friction: 0.8, restitution: 0.4))
world.compile()

for _ in 0..<1500 {
    world.step()
}

print(world.positions[2])   // 0.2 — resting exactly on the surface
```

Three things are worth noticing.

**`compile()` freezes the model.** Until you call it the world has no state
vectors: `compile()` assigns coordinate and degree-of-freedom offsets, builds the
child lists, sizes the caches, and resets to the default pose. Add all your
bodies first, then compile once.

**Position is stored in `positions`, not on the body.** Kinetic is a
reduced-coordinate engine. There is one flat `qpos` vector for the whole world;
a free body occupies seven entries (three for position, four for a quaternion)
and a revolute joint occupies one. See
[Frames, units and conventions](../concepts/conventions.md).

**The ball settles at exactly 0.2 m,** not 0.1995. Kinetic uses speculative
contacts, so a body approaching a surface is allowed to travel exactly the
remaining gap and no further. There is no steady-state penetration to tune away.

## An articulated arm

Bodies with joints are built link by link. Each link names its parent, and the
joint you attach describes how it moves relative to that parent.

```swift
let world = World()
world.addGround()

let arm = world.addArticulation(name: "arm")
var parent = -1                       // -1 means "attached to the world"

for (i, segment) in [(0.10, 0.075), (0.22, 0.06), (0.20, 0.05)].enumerated() {
    let link = world.addLink(articulation: arm, parent: parent, name: "link\(i)")

    world.setJoint(articulation: arm, link: link,
                   JointSpec.revolute(
                       axis: i == 0 ? Vec3(0, 0, 1) : Vec3(0, 1, 0),
                       origin: Pose(position: Vec3(0, 0, i == 0 ? 0.1 : segment.0 + 0.04)),
                       limits: -2.5...2.5,
                       damping: 2.0,
                       armature: 0.02))

    let shape = Shape.capsule(radius: segment.1, halfLength: segment.0 / 2)
    world.setInertial(articulation: arm, link: link, shape: shape, density: 1200)
    world.addGeom(articulation: arm, link: link,
                  GeomSpec(shape: shape,
                           localPose: Pose(position: Vec3(0, 0, segment.0 / 2))))

    world.addActuator(ActuatorSpec(kind: .position, articulation: arm, link: link,
                                   gear: 1, kp: 800, kd: 60))
    parent = link
}
world.compile()

world.control[1] = 0.6      // command the shoulder to 0.6 rad
world.step(2000)
```

`armature` is rotor inertia reflected through the gearbox. Real actuators have
it, and adding a little makes the mass matrix better conditioned — it is the
single most effective knob for making a high-gain position controller stable.

## Loading a real robot

```swift
let (world, robot) = try URDF.load(contentsOf: URL(fileURLWithPath: "panda.urdf"))
print(robot.links)                  // ["panda_link0", "panda_link1", ...]
print(world.dofCount)               // 6 (free base) + 7 (arm joints)
```

Meshes referenced with `package://` are resolved against the URDF's own
directory and its parent by default; add more search paths through
`URDFImportOptions.packageRoots`. Collision geometry becomes a convex hull;
visual geometry keeps its original triangles. See [Meshes](../formats/meshes.md).

## Watching it happen

Three ways, in increasing order of interactivity:

```bash
# 1. render one frame, headless
kinetic render stack --steps 400 --out stack.png

# 2. stream it to Foxglove or Studio
kinetic serve arm --port 8765

# 3. open the app
open "dist/Kinetic Studio.app"
```

## Reading results out

```swift
world.step()

world.contacts()             // [Contact] with point, normal, force, depth
world.profile                // per-stage timings, contact and constraint counts
world.sensorReadings         // flat sensor vector
world.totalEnergy            // kinetic + potential, in joules
world.centerOfMass           // SIMD3<Double>
world.angularMomentum        // about the system centre of mass

world.raycast(origin: Vec3(0, 0, 5), direction: Vec3(0, 0, -1))
world.pointJacobian(articulation: arm, link: tool, worldPoint: grip)
world.massMatrix(articulation: arm)
```

Anything the solver knows is reachable. There is no separate "debug build" that
exposes more.
