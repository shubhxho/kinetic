# Cookbook

Complete, runnable recipes. Each one is a whole program or a whole loop, not a
fragment — copy it, change the numbers, run it.

## Run a control loop at step rate

The pattern everything else is built on. Nothing here allocates after the first
iteration, so it holds at 2 kHz.

```swift
import Kinetic

let world = SceneLibrary.cartPole()
let cart = world.findArticulation("cartpole")!
let q = world.coordinateOffset(articulation: cart)
let v = world.dofOffset(articulation: cart)

// Hand-derived linear feedback: push the cart under the pole.
let gains = (x: -1.2, dx: -2.0, theta: 22.0, dtheta: 3.4)

for _ in 0..<5000 {
    let x      = world.positions[q + 0]
    let theta  = world.positions[q + 1]
    let dx     = world.velocities[v + 0]
    let dtheta = world.velocities[v + 1]

    let u = gains.x * x + gains.dx * dx + gains.theta * theta + gains.dtheta * dtheta
    world.control[0] = max(-1, min(1, u))

    world.step()
}

print(String(format: "pole angle after 10 s: %.4f rad", world.positions[q + 1]))
```

`positions`, `velocities` and `control` are views into engine memory, not copies.
Reading one is a load; writing one is a store.

## Resolved-rate control from the Jacobian

Move an end effector in a straight line in Cartesian space, without writing an
inverse-kinematics solver.

```swift
let world = SceneLibrary.articulatedArm()
let arm  = world.findArticulation("arm")!
let tool = world.findLink(articulation: arm, name: "tool")!
let n    = world.dofCount - world.dofOffset(articulation: arm)

func toolPosition() -> Vec3 {
    var index = 0
    for a in 0..<arm { index += world.linkCount(articulation: a) }
    return world.linkPoses()[index + tool].position
}

let target = toolPosition() + Vec3(0.10, 0.0, -0.05)

for _ in 0..<3000 {
    let position = toolPosition()
    let error = target - position
    if error.length < 1e-4 { break }

    // Damped least squares: J⁺ = Jᵀ (J Jᵀ + λ² I)⁻¹, which stays finite at a
    // singularity where the plain pseudo-inverse would blow up.
    let J = world.pointJacobian(articulation: arm, link: tool, worldPoint: position)
    let lambda = 0.05
    var JJt = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
    for r in 0..<3 {
        for c in 0..<3 {
            var sum = r == c ? lambda * lambda : 0
            for k in 0..<n { sum += J[r * n + k] * J[c * n + k] }
            JJt[r][c] = sum
        }
    }

    let rhs = [error.x, error.y, error.z]
    let solved = solve3x3(JJt, rhs)          // any small linear solve

    // qdot = Jᵀ (J Jᵀ + λ²I)⁻¹ e, integrated straight into the commanded pose.
    let base = world.coordinateOffset(articulation: arm)
    for k in 0..<min(n, world.actuatorCount) {
        var delta = 0.0
        for r in 0..<3 { delta += J[r * n + k] * solved[r] }
        world.control[k] = world.positions[base + k] + delta * 0.5
    }
    world.step()
}
```

## Sweep a parameter and keep every result

Deterministic simulation means a sweep is reproducible, so results can be cached
and compared across commits.

```swift
struct Trial {
    let friction: Double
    let slideDistance: Double
    let settledAfter: Double
}

func run(friction: Double) -> Trial {
    let world = World()
    world.addGround(friction: friction)
    let box = world.addRigidBody(name: "box",
                                 shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
                                 density: 500,
                                 pose: Pose(position: Vec3(0, 0, 0.1)))
    world.compile()
    world.setVelocity(articulation: box.articulation, linear: Vec3(3, 0, 0))

    var settled = 0.0
    for _ in 0..<3000 {
        world.step()
        if abs(world.velocities[0]) > 1e-3 { settled = world.time }
    }
    return Trial(friction: friction,
                 slideDistance: world.positions[0],
                 settledAfter: settled)
}

let results = stride(from: 0.05, through: 1.2, by: 0.05).map(run)
for trial in results {
    print(String(format: "μ=%.2f  slid %.3f m  stopped at %.2f s",
                 trial.friction, trial.slideDistance, trial.settledAfter))
}
```

Each `run` builds its own world, so these are trivially parallel with
`DispatchQueue.concurrentPerform` — `World` is not thread-safe, but independent
worlds are independent.

## Regression images in CI

Catch a physics change that no assertion covers by rendering the rest pose and
diffing the image.

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p artifacts
for scene in stack quadruped arm dominoes mixed; do
    ./.build/release/kinetic render "$scene" --steps 400 \
        --width 1200 --height 750 --out "artifacts/$scene.png"
done

# Compare against the committed baselines.
for scene in stack quadruped arm dominoes mixed; do
    if ! cmp -s "artifacts/$scene.png" "baselines/$scene.png"; then
        echo "changed: $scene"
        exit 1
    fi
done
```

`kinetic render` opens no window and needs no display session, so this works in
a headless runner. Because the engine is bit-deterministic the images are
byte-identical when nothing changed — a plain `cmp` is enough, no perceptual
diff required.

> The images are only byte-identical for the *same binary*. A toolchain or
> optimisation change can alter the last bit of a fused multiply-add, so
> regenerate baselines when you bump Swift.

## Drive a simulation from another process

The bridge accepts control input, so a policy in any language can close the loop.

```bash
kinetic serve cartpole --port 8765
```

```python
import asyncio, json, struct, websockets

async def main():
    async with websockets.connect(
        "ws://localhost:8765", subprotocols=["foxglove.websocket.v1"]
    ) as ws:
        await ws.recv()                                   # serverInfo
        advertise = json.loads(await ws.recv())
        state = next(c for c in advertise["channels"]
                     if c["topic"] == "/kinetic/state")

        await ws.send(json.dumps({"op": "subscribe",
                                  "subscriptions": [{"id": 0,
                                                     "channelId": state["id"]}]}))
        await ws.send(json.dumps({"op": "advertise",
                                  "channels": [{"id": 1, "topic": "/control",
                                                "encoding": "json",
                                                "schemaName": "kinetic.Control"}]}))

        while True:
            frame = await ws.recv()
            if not isinstance(frame, bytes) or frame[0] != 1:
                continue
            s = json.loads(frame[13:])
            x, theta = s["qpos"][0], s["qpos"][1]
            dx, dtheta = s["qvel"][0], s["qvel"][1]

            u = -1.2 * x - 2.0 * dx + 22.0 * theta + 3.4 * dtheta
            payload = json.dumps({"control": [max(-1.0, min(1.0, u))]}).encode()
            await ws.send(b"\x01" + struct.pack("<I", 1) + payload)

asyncio.run(main())
```

## Record a run and analyse it later

```swift
let world = SceneLibrary.quadruped()
let url = URL(fileURLWithPath: "walk.kinlog")
let recorder = try LogRecorder(url: url, world: world, title: "gait trial 3")

for step in 0..<5000 {
    world.control[1] = -0.8 + 0.35 * sin(Double(step) * 0.02)
    world.control[4] = -0.8 + 0.35 * sin(Double(step) * 0.02 + .pi)
    world.step()
    recorder.record(world)
}
recorder.finish()
```

```swift
let player = try LogPlayer(url: url)
let force = player.availableChannels.first { $0.label.contains("contact") }!
let (times, values) = try player.channel(force)

// Stride length from the gaps between ground contacts.
var strides: [Double] = []
var lastContact: Double?
for (t, v) in zip(times, values) where v > 0 {
    if let previous = lastContact, t - previous > 0.1 { strides.append(t - previous) }
    lastContact = t
}
print("mean stride period:", strides.reduce(0, +) / Double(strides.count))
```

Or skip the code entirely:

```bash
kinetic replay walk.kinlog --csv walk.csv
```

## Find the exact step where something broke

`saveState` and `loadState` make a bisection over time cheap.

```swift
let world = SceneLibrary.mixedPrimitives()
var snapshots: [(step: Int, state: [Double])] = []

for step in 0..<4000 {
    if step % 100 == 0 { snapshots.append((step, world.saveState())) }
    world.step()
    if !world.positions.allSatisfy({ $0.isFinite }) {
        print("diverged at step \(step)")

        // Rewind to the last good snapshot and single-step into the failure.
        if let last = snapshots.last {
            world.loadState(last.state)
            for offset in 0..<100 {
                world.step()
                let profile = world.profile
                if profile.solverResidual > 1e-3 {
                    print("step \(last.step + offset): residual \(profile.solverResidual), "
                          + "\(profile.contactCount) contacts")
                    break
                }
            }
        }
        break
    }
}
```

In Studio this is the timeline: drag backwards, watch the contact profile, find
the frame where the residual spiked.

## Build a sensor rig

```swift
let world = SceneLibrary.quadruped()
let robot = world.findArticulation("quadruped")!
let torso = world.findLink(articulation: robot, name: "torso")!

// A 16-beam planar lidar, one sensor per beam.
for beam in 0..<16 {
    let angle = Double(beam) / 16 * 2 * .pi
    world.addSensor(SensorSpec(
        name: "lidar_\(beam)",
        kind: .rangefinder,
        articulation: robot, link: torso,
        localPose: Pose(position: Vec3(0, 0, 0.08),
                        orientation: Quat(axis: Vec3(0, 0, 1), angle: angle)
                                   * Quat(axis: Vec3(0, 1, 0), angle: .pi / 2)),
        cutoff: 8.0))
}

world.addSensor(SensorSpec(name: "imu_gyro", kind: .gyroscope,
                           articulation: robot, link: torso,
                           noiseStandardDeviation: 0.002))
world.compile()

world.step()
let ranges = Array(world.sensorReadings.prefix(16))   // −1 where the beam missed
```

Sensor noise comes from a per-world seeded generator, so a noisy run is still
bit-reproducible.

## Attach a camera that follows a link

```swift
import KineticRender

let renderer = Renderer(sampleCount: 4)!
var settings = RenderSettings()
var camera = OrbitCamera()

let world = SceneLibrary.quadruped()
var linkIndex = 0
for a in 0..<world.findArticulation("quadruped")! {
    linkIndex += world.linkCount(articulation: a)
}

for frame in 0..<240 {
    world.step(8)

    let torso = world.linkPoses()[linkIndex].position
    camera.target = SIMD3<Float>(Float(torso.x), Float(torso.y), Float(torso.z))
    camera.azimuth = -0.9 + Float(frame) * 0.004
    camera.distance = 1.6

    if let image = renderer.snapshot(world: world, settings: settings,
                                     camera: camera, width: 1280, height: 720) {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: String(format: "frames/%04d.png", frame)))
    }
}
```

```bash
ffmpeg -framerate 30 -i frames/%04d.png -c:v h264 -pix_fmt yuv420p out.mp4
```

## Load a robot and check it before trusting it

```swift
var options = URDFImportOptions()
options.packageRoots = [URL(fileURLWithPath: "/path/to/ros_ws/src")]
options.fixedBase = true
options.onWarning = { print("urdf: \($0)") }

let (world, robot) = try URDF.load(contentsOf: url, options: options)

// Everything that has ever silently been wrong in an imported model.
print("links:", robot.links.count, "dof:", world.dofCount)
print("total mass:", world.totalMass, "kg")

for (index, name) in robot.links.enumerated() {
    let mass = world.mass(articulation: robot.articulation, link: index)
    if mass <= 0 { print("⚠︎ \(name) has no mass") }
    if mass > 200 { print("⚠︎ \(name) is \(mass) kg — check the units") }
}

world.forward()
if world.centerOfMass.z < 0 { print("⚠︎ centre of mass is below the origin") }
```

Then open it in Studio and drag every joint in the **Joints** tab. Sign errors in
a joint axis are invisible in XML and obvious in two seconds of dragging.

## Tune contacts for a specific feel

```swift
// Near-rigid: an assembly fixture that must not give.
SurfaceMaterial(friction: 0.6,
                stiffnessTimeConstant: 2 * world.options.timestep,
                dampingRatio: 1.0)

// Compliant: a foam pad or a soft gripper tip.
SurfaceMaterial(friction: 1.1,
                stiffnessTimeConstant: 0.08,
                dampingRatio: 1.4)

// Grippy foot that must not pivot in place.
SurfaceMaterial(friction: 1.3, torsionalFriction: 0.012)

// Bouncy.
SurfaceMaterial(friction: 0.5, restitution: 0.7)
```

Contact stiffness is derived against each constraint's own effective inertia, so
these settings behave the same whether the object weighs a gram or a tonne. See
[Materials](./concepts/materials.md).
