# Kinetic

Kinetic is a robotics simulator built for macOS. It is one repository containing
four things that usually come from four different projects:

- a **rigid-body physics engine** in C++20 — reduced-coordinate articulated
  dynamics, convex collision detection, and a soft-constraint solver;
- a **Metal renderer** — instanced physically-based shading, shadow mapping and
  debug overlays, running on Apple GPUs with no translation layer;
- **Kinetic Studio** — a native SwiftUI application for driving, inspecting and
  scrubbing a running simulation;
- a **telemetry server** that speaks the Foxglove WebSocket protocol, so any
  Foxglove client can visualise a Kinetic scene without a bridge process.

Everything is native. There is no Python runtime, no ROS installation, no
container, no CUDA. `swift build` produces the whole system in under a minute
and the result is a single Mach-O binary plus an app bundle.

```bash
git clone https://github.com/shubhxho/kinetic
cd kinetic
swift build -c release
./.build/release/kinetic validate
```

## What it is for

Kinetic is aimed at the loop you actually spend time in: change a model or a
controller, watch what happens, work out why it happened.

That means the parts most simulators treat as afterthoughts are first-class
here. Contact forces are drawn as arrows, not hidden in a log. The solver
publishes its own residual and iteration count as a plottable channel. The
timeline holds the last twenty seconds of full simulation state, so when
something goes wrong you drag backwards into it rather than restarting with more
print statements.

## What it is not

- **Not a GPU-parallel training farm.** Isaac Sim and Isaac Lab exist to run
  thousands of environments at once on NVIDIA hardware. Kinetic runs one world
  extremely well on the machine you are sitting at. If your bottleneck is
  reinforcement-learning throughput, this is the wrong tool.
- **Not a photorealistic renderer.** The viewport is a real PBR renderer with
  shadows and tone mapping, but it is built to make *physics* legible, not to
  produce marketing footage.
- **Not cross-platform.** The physics core is portable C++ with no dependencies,
  but the renderer is Metal and the app is AppKit and SwiftUI.

## A tour in one page

```swift
import Kinetic

let world = World()
world.addGround(friction: 1.0)

for i in 0..<10 {
    world.addRigidBody(
        name: "box\(i)",
        shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
        density: 500,
        pose: Pose(position: Vec3(0, 0, 0.1 + 0.2005 * Double(i))))
}
world.compile()

world.step(3000)                     // six seconds at the default 500 Hz
print(world.contacts().count)        // 40 contact points holding the tower up
print(world.centerOfMass)            // SIMD3<Double>(0.0, 0.0, 1.0)
```

The same model can be loaded from URDF or MJCF, streamed to Foxglove, recorded
to a seekable `.kinlog`, rendered headless to a PNG, or opened in Studio.

## How the book is organised

| Part | What it covers |
| --- | --- |
| [Getting started](./getting-started/install.md) | Building, the first simulation, Studio and the CLI |
| [Concepts](./concepts/architecture.md) | How the pieces fit, and the conventions everything obeys |
| [Physics](./physics/dynamics.md) | The actual algorithms, with the equations they implement |
| [Formats](./formats/urdf.md) | What Kinetic reads and writes, and where the edges are |
| [Telemetry](./telemetry/foxglove.md) | Streaming a live simulation to external tools |
| [API reference](./api/swift.md) | The Swift and C surfaces |
| [Reference](./reference/benchmarks.md) | Measured numbers, comparisons and shortcuts |

If you want to understand the engine rather than use it, start at
[Rigid-body dynamics](./physics/dynamics.md) — it explains the coordinate
choice that everything else follows from.

## Status

Version 1.0. The physics core is validated against closed-form solutions and
conservation laws on every commit; see
[Accuracy and validation](./physics/accuracy.md) for the current numbers and
exactly what each check proves.
