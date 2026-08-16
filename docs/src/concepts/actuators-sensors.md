# Actuators and sensors

## Actuators

An actuator drives one degree of freedom. Its input is a scalar in
`world.control`; its output is the force written to `world.actuatorForces`.

```swift
world.addActuator(ActuatorSpec(
    name: "shoulder",
    kind: .position,
    articulation: robot,
    link: shoulder,
    gear: 1,
    kp: 800, kd: 60,
    controlRange: -1.9...1.9,
    forceRange: -200...200))
```

| Kind | Force |
| --- | --- |
| `.motor` | `gear · u` |
| `.position` | `gear · (kp·(u − q) − kd·q̇)` |
| `.velocity` | `gear · kp·(u − q̇)` |
| `.damper` | `−gear · u · q̇` |

The output is clamped to `forceRange` and then to the joint's `effortLimit` if
one is set.

### Derivative gains are implicit

For `.position` and `.velocity`, the derivative term is folded into the mass
matrix before factorisation:

\\[ (M + h\\,\\text{diag}(\\text{gear} \\cdot k_d))\\,\\ddot q = \\tau - c - \\dots \\]

This removes the usual stability ceiling on \\(k_d\\). `kp: 800, kd: 60` is
stable at 500 Hz; with an explicit integrator the same gains would need several
kilohertz or would ring.

### Writing control

```swift
world.control[0] = 0.6          // by index
if let i = world.findActuator("shoulder") { world.control[i] = 0.6 }
```

`control` is a live view into engine memory, so a controller running at step rate
allocates nothing.

A typical loop:

```swift
for _ in 0..<steps {
    let angle = world.positions[shoulderCoordinate]
    let rate  = world.velocities[shoulderDof]
    world.control[0] = policy(angle, rate)
    world.step()
}
```

### External forces

For pushes, wind, thrusters, or a scripted disturbance:

```swift
world.applyForce(articulation: robot, link: torso,
                 force: Vec3(50, 0, 0), at: contactPoint)
world.applyTorque(articulation: robot, link: torso, torque: Vec3(0, 0, 2))
world.step()
world.clearAppliedForces()      // they do not persist
```

Applied wrenches are accumulated per link and mapped to generalised force by the
transpose Jacobian, so they are exact for articulated bodies rather than
approximated at the root.

## Sensors

Sensors write into one flat `sensorReadings` vector at fixed offsets assigned by
`compile()`.

```swift
world.addSensor(SensorSpec(name: "imu_gyro", kind: .gyroscope,
                           articulation: robot, link: torso,
                           localPose: Pose(position: Vec3(0, 0, 0.02)),
                           noiseStandardDeviation: 0.002,
                           bias: 0.0001))
```

| Kind | Dim | Reads |
| --- | --- | --- |
| `.jointPosition` | 1 | the link's joint coordinate |
| `.jointVelocity` | 1 | the link's joint velocity |
| `.actuatorForce` | 1 | force produced by an actuator |
| `.accelerometer` | 3 | proper acceleration at the site, site frame |
| `.gyroscope` | 3 | angular velocity, site frame |
| `.framePosition` | 3 | site position, world frame |
| `.frameOrientation` | 4 | site orientation as a quaternion |
| `.frameLinearVelocity` | 3 | site velocity, world frame |
| `.forceTorque` | 6 | contact wrench on the link, site frame |
| `.contactNormalForce` | 1 | total normal force on the link |
| `.rangefinder` | 1 | ray distance along the site's +Z, −1 on a miss |

### The accelerometer measures proper acceleration

Like a real IMU. A body at rest reads +9.81 m/s² upward, not zero; a body in free
fall reads zero. The computation uses the full link spatial acceleration
including the solved `qacc`, so contact impulses show up in the reading the same
step they occur.

### Rangefinders ignore their own robot

A rangefinder casts along its site's +Z and excludes its own articulation, so it
does not return the robot it is mounted on. It respects group masks, so a sensor
can be made blind to specific objects.

```swift
world.addSensor(SensorSpec(name: "lidar_0", kind: .rangefinder,
                           articulation: robot, link: head,
                           localPose: Pose(orientation: Quat(axis: Vec3(0, 1, 0),
                                                             angle: .pi / 2)),
                           cutoff: 12.0))    // max range in metres
```

For a full scan, add one sensor per beam or call `world.raycast` directly.

### Noise and bias

`noiseStandardDeviation` adds zero-mean Gaussian noise from a **per-world seeded
generator**, so a noisy run is still bit-reproducible. `bias` is a constant
offset. `cutoff` clamps the reading (and doubles as maximum range for
rangefinders).

### Reading sensors

```swift
world.step()
let readings = world.sensorReadings      // flat, offsets from compile()

for (i, name) in world.sensorNames.enumerated() {
    let dim = world.sensorKinds[i].dimension
    // offsets accumulate in declaration order
}
```

In Studio every sensor component appears in the telemetry channel picker by name,
and the bridge publishes them all as a keyed JSON object on `/kinetic/sensors`.
