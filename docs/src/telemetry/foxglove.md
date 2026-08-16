# Connecting Foxglove

Kinetic serves the Foxglove WebSocket protocol directly. There is no bridge
process, no ROS installation and no bag conversion — the simulator *is* the
server.

## Start the server

From the CLI:

```bash
kinetic serve quadruped --port 8765
```

From Studio: the antenna button in the toolbar, or `⌘K` → "Start telemetry
server".

From code:

```swift
import KineticBridge

let bridge = FoxgloveBridge(world: world)
bridge.publishRate = 30
try bridge.start(port: 8765)

for _ in 0..<steps {
    world.step()
    bridge.publishIfNeeded()
}
```

## Connect

In Foxglove: **Open connection → Foxglove WebSocket** → `ws://localhost:8765`.

Add a **3D** panel. The scene appears, with the transform tree populated and
contact points and force arrows overlaid. Add a **Plot** panel and any numeric
field under `/kinetic/state`, `/kinetic/sensors` or `/kinetic/profile` is
plottable.

## Topics

| Topic | Schema | Contents |
| --- | --- | --- |
| `/kinetic/scene` | `foxglove.SceneUpdate` | every visible geom as a cube, sphere or cylinder |
| `/kinetic/contacts` | `foxglove.SceneUpdate` | contact points and force arrows |
| `/kinetic/tf` | `foxglove.FrameTransforms` | one transform per link, parented to `world` |
| `/kinetic/state` | `kinetic.State` | time, qpos, qvel, ctrl, actuator forces, com, energy |
| `/kinetic/profile` | `kinetic.StepProfile` | per-stage timings, contact and constraint counts, solver residual |
| `/kinetic/sensors` | `kinetic.Sensors` | every sensor keyed by name |

Capsules have no Foxglove primitive, so they are published as a cylinder plus two
end spheres, which reproduces the silhouette exactly.

## Sending control back

The server advertises the `clientPublish` capability, so a client can drive the
simulation. Publish JSON to any client-advertised channel:

```json
{"index": 3, "value": 0.42}
```

or set the whole vector at once:

```json
{"control": [0.0, -0.8, 1.6, 0.0, -0.8, 1.6, 0.0, -0.8, 1.6, 0.0, -0.8, 1.6]}
```

This is enough to build a teleoperation panel, or to drive Kinetic from a policy
running in another process or another language.

## Rate and backpressure

`publishRate` (30 Hz by default) is independent of the simulation rate — a
500 Hz sim publishing at 30 Hz sends every 17th state. `publishIfNeeded()` is
cheap to call after every step.

Each connection has an 8 MB pending-write budget. A client that falls behind has
frames **dropped**, not queued: for live telemetry, current data late-free beats
stale data in order.

## Why this instead of a Foxglove-alike panel

Kinetic Studio and Foxglove are good at different things, and they read the same
socket.

Studio owns the simulation: it can pause, single-step, scrub twenty seconds of
full state backwards, pose joints directly, and change solver parameters while
running. None of that is expressible over a telemetry protocol, because it
requires *being* the simulator.

Foxglove owns the surrounding workflow: layouts shared across a team, panels for
data Kinetic knows nothing about, and the same view for a simulated run and a
real robot. Speaking its protocol means a team's existing layouts work against a
Kinetic scene on day one.

So: use Studio while iterating, Foxglove when what you are looking at has to sit
next to something else.
