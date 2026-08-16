# Swift API

```swift
import Kinetic
```

Everything except `World` is a value type. `World` is the single reference type,
because it owns the C handle.

## World

### Construction

```swift
let world = World()

world.addArticulation(name: String) -> Int
world.addLink(articulation: Int, parent: Int = -1, name: String) -> Int
world.setJoint(articulation: Int, link: Int, _ joint: JointSpec)
world.setInertial(articulation: Int, link: Int, mass: Double, com: Vec3, inertia: [Double])
world.setInertial(articulation: Int, link: Int, shape: Shape, density: Double, com: Vec3 = .zero)
world.addGeom(articulation: Int, link: Int, _ geom: GeomSpec) -> Int
world.addMesh(vertices: [Vec3], indices: [UInt32], name: String) -> Int
world.addActuator(_ spec: ActuatorSpec) -> Int
world.addSensor(_ spec: SensorSpec) -> Int
world.compile()
```

### Convenience

```swift
world.addGround(height: Double = 0, friction: Double = 1.0, extent: Double = 60) -> Int
world.addRigidBody(name:shape:density:pose:material:appearance:) -> RigidBody
world.addStaticBody(name:shape:pose:material:appearance:) -> Int
world.connect(articulationA:linkA:anchorA:articulationB:linkB:anchorB:) -> Int
world.weld(articulationA:linkA:articulationB:linkB:anchorA:anchorB:relativeOrientation:) -> Int
world.setSelfCollision(articulation: Int, enabled: Bool)
world.setEnabled(articulation: Int, enabled: Bool)
world.setDefaultPose(articulation: Int, q: [Double])
```

### Simulation

```swift
world.step(_ count: Int = 1)
world.forward()          // kinematics and derived quantities, without integrating
world.reset()            // back to the default pose
world.time               // seconds, get and set
world.options            // SimulationOptions, get and set
```

### State

Live views into engine memory. Invalidated by `compile()`.

```swift
world.positions          // UnsafeMutableBufferPointer<Double>, size nq
world.velocities         // size nv
world.accelerations      // size nv
world.control            // size nu
world.actuatorForces     // size nu
world.sensorReadings     // size nsensordata
world.appliedGeneralizedForces   // size nv

world.saveState() -> [Double]
world.loadState(_ state: [Double])
```

### Sizes and lookup

```swift
world.coordinateCount        // nq
world.dofCount               // nv
world.actuatorCount
world.sensorDataCount
world.articulationCount
world.linkCount
world.geomCount

world.coordinateOffset(articulation: Int) -> Int
world.dofOffset(articulation: Int) -> Int
world.linkCount(articulation: Int) -> Int

world.findArticulation(_ name: String) -> Int?
world.findLink(articulation: Int, name: String) -> Int?
world.findActuator(_ name: String) -> Int?
world.name(articulation: Int) -> String
world.name(articulation: Int, link: Int) -> String
```

### Queries

```swift
world.contacts() -> [Contact]
world.profile -> StepProfile
world.linkPoses() -> [Pose]
world.geomPoses() -> [Pose]
world.geomInfo -> [GeomInfo]
world.meshData(_ index: Int) -> (vertices: [Vec3], indices: [UInt32])

world.raycast(origin:direction:maxDistance:mask:ignoring:) -> RaycastHit?
world.pointJacobian(articulation:link:worldPoint:) -> [Double]     // 3 × nv, row-major
world.massMatrix(articulation:) -> [Double]                        // nv × nv, row-major

world.kineticEnergy
world.potentialEnergy
world.totalEnergy
world.totalMass
world.centerOfMass
world.linearMomentum
world.angularMomentum        // about the centre of mass

world.jointKind(articulation:link:) -> JointKind
world.jointLimits(articulation:link:) -> ClosedRange<Double>?
world.mass(articulation:link:) -> Double
world.parent(articulation:link:) -> Int
```

### Forces

```swift
world.applyForce(articulation:link:force:at:)
world.applyTorque(articulation:link:torque:)
world.clearAppliedForces()
```

### Poses

```swift
world.setPose(articulation: Int, _ pose: Pose)
world.pose(articulation: Int) -> Pose
world.setVelocity(articulation: Int, linear: Vec3, angular: Vec3 = .zero)
```

## Value types

```swift
typealias Vec3 = SIMD3<Double>
typealias Vec4 = SIMD4<Double>

struct Quat  { w, x, y, z; init(axis:angle:), init(roll:pitch:yaw:), rotate(_:), eulerRPY }
struct Pose  { position: Vec3; orientation: Quat; apply(_:), applyInverse(_:), inverse, * }

enum Shape { .sphere, .box, .capsule, .cylinder, .plane, .convexHull }
enum JointKind { .fixed, .revolute, .prismatic, .spherical, .free }
enum ActuatorKind { .motor, .position, .velocity, .damper }
enum SensorKind { .jointPosition, .jointVelocity, .actuatorForce, .accelerometer,
                  .gyroscope, .framePosition, .frameOrientation, .frameLinearVelocity,
                  .forceTorque, .contactNormalForce, .rangefinder }
enum Integrator { .semiImplicitEuler, .rungeKutta4, .implicitFast }

struct SurfaceMaterial { friction, torsionalFriction, restitution,
                         stiffnessTimeConstant, dampingRatio, margin }
struct Appearance      { color, metallic, roughness, emissive }
struct GeomSpec        { shape, localPose, material, appearance, collidable, visible,
                         group, mask, name }
struct JointSpec       { kind, axis, origin, limited, lower, upper, effortLimit,
                         velocityLimit, damping, friction, armature, stiffness,
                         springReference }
struct ActuatorSpec    { name, kind, articulation, link, gear, kp, kd,
                         controlRange, forceRange }
struct SensorSpec      { name, kind, articulation, link, localPose,
                         noiseStandardDeviation, bias, cutoff }
struct SimulationOptions { timestep, integrator, gravity, solverIterations,
                           relaxationIterations, solverTolerance, warmStart,
                           contactMargin, penetrationSlop, maxCorrectionVelocity,
                           linearDamping, angularDamping, maxVelocity,
                           enableContacts, enableJointLimits, enableEqualities,
                           multithreaded }

struct Contact     { point, normal, force, depth, geomA, geomB, normalForce }
struct StepProfile { kinematics, inertia, bias, collision, constraintSetup, solve,
                     integrate, sensors, total, contactCount, constraintCount,
                     broadphasePairs, solverIterations, solverResidual }
struct RaycastHit  { distance, point, normal, geom, articulation, link }
struct GeomInfo    { index, name, shape, appearance, articulation, link,
                     visible, collidable }
```

## Importers

```swift
URDF.load(contentsOf: URL, into: World? = nil, options: URDFImportOptions)
    throws -> (world: World, robot: Robot)
URDF.load(data: Data, into: World? = nil, options: URDFImportOptions)
    throws -> (world: World, robot: Robot)

MJCF.load(contentsOf: URL, into: World? = nil, options: MJCFImportOptions)
    throws -> (world: World, robot: Robot)
```

## Meshes and hulls

```swift
MeshLoader.load(contentsOf: URL, scale: Vec3) throws -> LoadedMesh
MeshLibrary(searchPaths: [URL]).load(_ uri: String, scale: Vec3) throws -> LoadedMesh
ConvexHull.compute(points: [Vec3], tolerance: Double, maxVertices: Int) -> ConvexHullResult
```

## Recording

```swift
let recorder = try LogRecorder(url: URL, world: World, title: String)
recorder.record(world)
recorder.finish()

let player = try LogPlayer(url: URL)
player.header, player.frameCount, player.duration
try player.frame(at: Int) -> LogFrame
player.index(forTime: Double) -> Int
player.availableChannels -> [LogChannel]
try player.channel(_ channel: LogChannel) -> (times: [Double], values: [Double])
try player.exportCSV(channels: [LogChannel], to: URL)
```

## Scenes

```swift
SceneLibrary.all                  // [Entry] with id, title, summary, build
SceneLibrary.build("quadruped")   // World?

SceneLibrary.boxStack(count: 10)
SceneLibrary.articulatedArm()
SceneLibrary.quadruped()
SceneLibrary.cartPole()
SceneLibrary.pendulumChain(links: 20)
SceneLibrary.dominoes(count: 60)
SceneLibrary.mixedPrimitives()
```

## Rendering and telemetry

```swift
import KineticRender
let renderer = Renderer(sampleCount: 4)
renderer?.snapshot(world:settings:camera:width:height:) -> CGImage?

import KineticBridge
let bridge = FoxgloveBridge(world: world)
try bridge.start(port: 8765)
bridge.publishIfNeeded()
```
