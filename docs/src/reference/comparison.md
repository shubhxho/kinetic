# How Kinetic compares

An honest reading of where Kinetic sits. Every tool listed here is good at
something Kinetic is not.

## Against Isaac Sim / Isaac Lab

| | Isaac Sim | Kinetic |
| --- | --- | --- |
| Platform | Linux, Windows | macOS |
| Hardware | NVIDIA GPU required | any Metal Mac |
| Parallel environments | thousands, GPU-batched | one |
| Photorealistic rendering | RTX path tracing | PBR raster viewport |
| Install | multi-GB, Omniverse runtime | `swift build`, under a minute |
| Startup | tens of seconds | milliseconds |
| Determinism | GPU-order dependent | bit-identical, threaded or not |
| Sensors | cameras, lidar, IMU, contact | IMU, contact, force-torque, rangefinder, frame |
| Scripting | Python | Swift, C, or anything with a C FFI |

**Choose Isaac** if your bottleneck is reinforcement-learning throughput or you
need photoreal synthetic data. Thousands of parallel environments on a GPU is a
real capability and Kinetic does not have it.

**Choose Kinetic** if you are on a Mac, if you iterate on models and controllers
rather than train policies at scale, or if you want to read the engine you are
depending on.

## Against MuJoCo

The closest comparison — MuJoCo is also a reduced-coordinate engine with a soft
constraint model, and Kinetic's `solref` parameterisation is deliberately
compatible.

| | MuJoCo | Kinetic |
| --- | --- | --- |
| Coordinates | reduced | reduced |
| Solver | PGS / CG / Newton on a convex formulation | PGS with speculative contacts |
| Friction | pyramidal or elliptic cone | true second-order cone |
| Contact model | soft, `solref`/`solimp` | soft, time constant + damping ratio |
| Continuous collision | none | speculative contacts + swept bounds |
| Tendons, muscles, flex | yes | no |
| Native viewer | yes, functional | yes, and the primary interface |
| Platforms | Linux, macOS, Windows | macOS |
| Language | C, Python bindings | C++, C ABI, Swift |
| Maturity | a decade, enormous model zoo | version 1.0 |

MuJoCo is more capable and far more battle-tested. It has tendons, muscles,
deformables, an established model ecosystem and years of published validation.

Kinetic's genuine differences: contacts are speculative, so fast bodies do not
tunnel and resting bodies do not sink; friction is a true cone rather than a
pyramid, so sliding is isotropic; and the tooling — timeline scrubbing over full
state, a Foxglove-compatible server — is part of the simulator rather than
something you assemble.

If you have MuJoCo models, load them: the MJCF importer covers the rigid-body
subset and `solref` carries over.

## Against Bullet / PyBullet

| | Bullet | Kinetic |
| --- | --- | --- |
| Coordinates | maximal, with a reduced-coordinate mode | reduced |
| Joint drift | possible under stiff loads | impossible by construction |
| Determinism | best-effort | bit-identical |
| Precision | float | double |
| Ecosystem | very large | new |

Bullet's maximal-coordinate core means joints are constraints that can be
violated. Kinetic's tree is exact, which matters most for long articulated chains
and high-gear-ratio joints.

## Against Foxglove

Foxglove is a visualisation platform, not a simulator, so this is about the
overlap.

| | Foxglove | Kinetic Studio |
| --- | --- | --- |
| Data sources | ROS, MCAP, protobuf, WebSocket, many others | its own simulation |
| Layouts | shareable, team-wide | fixed, purpose-built |
| Panels | large library, extensible | 3D, plots, joints, actuators, log |
| Controls the source | no | yes — pause, step, scrub, pose, retune |
| Full-state time travel | no (replays messages) | yes (restores simulation state) |
| Runs against a real robot | yes | no |

The two are complementary, and they read the same socket: Kinetic **serves the
Foxglove protocol**, so existing team layouts work against a Kinetic scene with
no bridge.

Where Studio is genuinely better is the loop where you own the simulation.
Scrubbing a Foxglove recording replays *messages*; scrubbing Kinetic's timeline
restores *simulation state*, so the contact set, the solver residual and every
derived quantity are exactly what they were — and you can resume from that point.

Where Foxglove is better: everything involving real hardware, heterogeneous data
sources, and sharing a view with people who are not running your simulator.

## Against Gazebo

| | Gazebo | Kinetic |
| --- | --- | --- |
| ROS integration | first-class | none (bridge over WebSocket) |
| Physics backends | ODE, Bullet, DART, Simbody | one, in-tree |
| Plugin ecosystem | large | none |
| Sensors | very broad, including cameras | rigid-body sensors only |
| Setup | substantial | `swift build` |

If your work is ROS-shaped, Gazebo (or Isaac) fits the surrounding tooling in a
way Kinetic does not. Kinetic has no ROS integration and no plugin system.

## What Kinetic does not have

Stated plainly:

- no GPU-parallel environment batching
- no soft bodies, cloth, fluids or deformables
- no tendons or muscle models
- no camera or lidar *rendering* sensors (rangefinder rays only)
- no ROS or ROS 2 integration
- no Linux or Windows support
- no plugin system
- no published peer-reviewed validation, only the in-repo suite

## What Kinetic does have

- a physics core you can read end to end in an afternoon
- bit-identical determinism, including with threading on
- contacts that neither tunnel nor sink
- twenty seconds of full-state time travel in the viewer
- a Foxglove-compatible server with no bridge process
- one build command, no runtime, no container
