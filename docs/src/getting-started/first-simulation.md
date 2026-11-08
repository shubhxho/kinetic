# Your first simulation

## On the command line

After `swift build -c release` (see [Install](./install.md)):

```bash
./.build/release/kinetic list
./.build/release/kinetic config
./.build/release/kinetic run stack --duration 1
```

`list` is the seven built-in ids. `config` prints duration, port, rate, serial
and whether `GITHUB_TOKEN` is set, naming the flag, env or default that won.
`run stack --duration 1` steps the ten-box tower for one simulated second and
prints realtime factor, mean step cost, contact count and total energy. No
Metal, no Studio, no extra files.

`kinetic run`, `validate`, `bench` and `info` do not need a GPU.
`kinetic render` and Studio do.

The rest of this page is the Swift API for the same engine.

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

print(world.positions[2])   // 0.2 m, sitting on the plane
```

This is the same setup `kinetic validate` uses for resting contact. On a
macOS release build that check reports 0.000 mm penetration. This Linux
checkout cannot run the Swift snippet.

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

**The ball settles at 0.2 m,** not 0.1995. Kinetic uses speculative
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
it, and adding a little makes the mass matrix better conditioned. It is the
single most effective knob for making a high-gain position controller stable.

The built-in six-axis arm is `SceneLibrary.build("arm")` or `kinetic run arm`.

## Loading a real robot

There is no `panda.urdf` in this repository. Use a built-in scene, or fetch a
registry model (needs network; a dummy `GITHUB_TOKEN` is documented in
[Configuration](./configuration.md)):

```swift
let armWorld = SceneLibrary.articulatedArm()
print(armWorld.dofCount)

let library = ModelLibrary()
_ = try await library.fetch("franka-panda")
let (panda, robot) = try library.load("franka-panda")
print(robot.links)
print(panda.dofCount)
```

A URDF loaded through `URDF.load` gets a free root unless you set
`URDFImportOptions.fixedBase = true`, so `dofCount` is 6 plus each movable
joint. `library.load` uses the registry entry's own import options.

Meshes referenced with `package://` are resolved against the URDF's own
directory and its parent by default; add more search paths through
`URDFImportOptions.packageRoots`. Collision geometry becomes a convex hull;
visual geometry keeps its original triangles. See [Meshes](../formats/meshes.md).

## Watching it happen

Three ways, in increasing order of interactivity:

```bash
# 1. render one frame, headless (Metal required)
kinetic render stack --steps 400 --out stack.png

# 2. stream it to Foxglove or Studio
kinetic serve arm --port 8765

# 3. open the app (after Scripts/bundle-app.sh release)
open "dist/Kinetic Studio.app"
```

USD files are not accepted by the CLI; use `USDImporter` from Swift. See
[Configuration](./configuration.md) for ports, cache and `GITHUB_TOKEN`.

Scene figures in this book (arm, chain, dominoes, mixed, quadruped, stack,
go2) are headless `kinetic render` captures from macOS, 1600x1000. They are
not screenshots of a live Studio window. This tree has none of those.

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
