<div align="center">

# Kinetic

**Native macOS robotics simulation.**
Rigid-body physics, a Metal renderer, and Foxglove-compatible telemetry — in one repository, with no runtime to install.

[Documentation](https://shubhxho.github.io/kinetic) ·
[Getting started](https://shubhxho.github.io/kinetic/getting-started/install.html) ·
[Physics](https://shubhxho.github.io/kinetic/physics/dynamics.html) ·
[Benchmarks](https://shubhxho.github.io/kinetic/reference/benchmarks.html)

</div>

---

```bash
git clone https://github.com/shubhxho/kinetic
cd kinetic
swift build -c release
./.build/release/kinetic validate
```

No Python. No ROS. No container. No CUDA. One build command, under a minute.

## What is in here

| Layer | What it is |
| --- | --- |
| **KineticCore** | C++20 rigid-body physics — reduced-coordinate articulated dynamics, convex collision, soft-constraint solver. No dependencies. |
| **kinetic.h** | A stable C ABI, ~90 entry points. Bindable from anything with a C FFI. |
| **Kinetic** | Swift API, URDF and MJCF importers, mesh loading, Quickhull, `.kinlog` recording. |
| **KineticRender** | Metal forward PBR renderer — instanced geometry, shadow mapping, contact and frame overlays, headless snapshots. |
| **KineticBridge** | A hand-written RFC 6455 server speaking the Foxglove WebSocket protocol. |
| **KineticStudio** | SwiftUI app: viewport, timeline scrubbing over full simulation state, live plots, joint posing, command palette. |

## Physics

- **Reduced coordinates.** Joints are exact by construction and cannot drift, no matter the timestep or gear ratio. CRBA for the joint-space inertia, RNEA for bias forces, LDLᵀ with implicit damping folded in.
- **Speculative contacts.** A separated point may approach by at most its remaining gap this step. Resting bodies sit at exactly their radius — **zero** steady-state penetration — and a 120 m/s projectile stops dead at a 10 mm wall.
- **True friction cone.** Second-order cone projection, not a pyramid, so grip is isotropic and sliding objects do not curve.
- **Physically parameterised contact.** A time constant and a damping ratio, derived against each constraint's own effective inertia, so a 1 g screw and a 1 t chassis settle identically from the same setting.
- **Bit-identical determinism**, including with the threaded narrowphase enabled. Asserted on every run.

## Validated, not asserted

```text
$ kinetic validate

  PASS  free fall                         error 0.00 nm
  PASS  resting contact                   penetration 0.000 mm
  PASS  pendulum energy drift             0.210 % over 10 s
  PASS  angular momentum (RK4)            drift 0.0008 %
  PASS  Coulomb friction                  held 0.00 mm, slid 1.623 m
  PASS  box stack stability               max drift 7.31 mm
  PASS  no tunnelling at 120 m/s          stopped at x = -0.1114 m
  PASS  threaded narrowphase determinism  420 coordinates compared
  PASS  determinism                       168 coordinates compared

  all checks passed
```

Every check is a closed-form or conservation-law comparison. Plus 44 unit tests
across nine suites. [What each one proves.](https://shubhxho.github.io/kinetic/physics/accuracy.html)

## Performance

Apple M4, single-threaded except where noted, double precision:

| Scene | nv | ms/step | realtime |
| --- | --- | --- | --- |
| cartpole | 2 | 0.0005 | 4124× |
| 6-DOF arm | 6 | 0.0015 | 1362× |
| 20-link chain | 20 | 0.0040 | 497× |
| quadruped | 18 | 0.0141 | 142× |
| 10-box stack | 60 | 0.0868 | 23× |
| 60 dominoes | 360 | 0.3948 | 5.1× |

## Thirty seconds of it

```swift
import Kinetic

let world = World()
world.addGround(friction: 1.0)

for i in 0..<10 {
    world.addRigidBody(name: "box\(i)",
                       shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
                       density: 500,
                       pose: Pose(position: Vec3(0, 0, 0.1 + 0.2005 * Double(i))))
}
world.compile()
world.step(3000)

print(world.contacts().count)   // 40 contact points holding the tower up
```

```bash
kinetic info panda.urdf                       # inspect a model
kinetic run quadruped --duration 10 --record walk.kinlog
kinetic bench                                 # benchmark every scene
kinetic render stack --steps 400 --out stack.png
kinetic serve arm --port 8765                 # stream to Foxglove
```

## Kinetic Studio

```bash
./Scripts/bundle-app.sh release
open "dist/Kinetic Studio.app"
```

- **Timeline scrubbing over full simulation state.** Twenty seconds of every
  `qpos`, `qvel` and contact set, restored directly. Not a replay of messages —
  the actual state, resumable.
- **Command palette** (`⌘K`) for every action.
- **Live plots** of any channel the model exposes: joints, sensors, actuator
  forces, step time, solver residual, energy.
- **Joint posing** — drag a slider, watch the link move, verify an imported
  URDF's axes.
- **Solver parameters editable while running.**

## Talks to Foxglove, no bridge

Kinetic *is* the WebSocket server. Point any Foxglove client at
`ws://localhost:8765` and the scene appears in its 3D panel with a live transform
tree, contact arrows, and every numeric channel plottable. Clients can publish
control back.

## Formats

| Reads | Writes |
| --- | --- |
| URDF, MJCF | `.kinlog` (seekable, self-describing) |
| STL (binary + ASCII), OBJ, ASCII PLY | CSV channel export |
| | PNG (headless render) |

## What it is not

- **Not a GPU training farm.** One world, extremely well. If you need thousands
  of parallel environments, use Isaac.
- **Not photorealistic.** The viewport makes physics legible, not marketing
  footage.
- **Not cross-platform.** The physics core is portable C++; the renderer is Metal.
- **No soft bodies, cloth, fluids, tendons or camera sensors.**

[The full comparison, including where MuJoCo, Bullet, Gazebo and Foxglove win.](https://shubhxho.github.io/kinetic/reference/comparison.html)

## Requirements

macOS 14+, Xcode 15+, a Metal 3 GPU.

## Documentation

```bash
brew install mdbook
mdbook serve docs --open
```

24 chapters: getting started, the conventions everything obeys, the actual
algorithms with their equations, both file formats, the wire protocol, both API
surfaces, benchmarks and troubleshooting.

## License

MIT.
