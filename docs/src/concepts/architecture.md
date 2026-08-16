# Architecture

Kinetic is five layers. Each one depends only on the layer below it, and each can
be used without the ones above.

```text
┌─────────────────────────────────────────────────────────────┐
│  KineticStudio          SwiftUI app, timeline, palette      │
├──────────────────────────┬──────────────────────────────────┤
│  KineticRender           │  KineticBridge                   │
│  Metal PBR viewport      │  Foxglove WebSocket server       │
├──────────────────────────┴──────────────────────────────────┤
│  Kinetic                 Swift API, URDF/MJCF, meshes,      │
│                          convex hulls, .kinlog recording    │
├─────────────────────────────────────────────────────────────┤
│  kinetic.h               stable C ABI, ~90 entry points     │
├─────────────────────────────────────────────────────────────┤
│  KineticCore             C++20 physics, no dependencies     │
└─────────────────────────────────────────────────────────────┘
```

## Why a C ABI in the middle

The physics core is C++ and the rest is Swift. Swift's direct C++ interoperation
works, but it couples the two languages' build settings, makes the boundary
implicit, and leaves no obvious place to version the contract.

`kinetic.h` is a flat C header of plain-data structs and opaque handles. It costs
a thin translation layer and buys three things: the engine is callable from any
language with a C FFI, the boundary is a file you can read to know exactly what
is public, and the Swift side can be rewritten without touching physics.

## KineticCore

Roughly 5,000 lines of C++20 with no third-party dependencies — not even Eigen.
The linear algebra is small and fixed-size (3-vectors, quaternions, 3×3 and 6×6
spatial matrices) plus a dense LDLᵀ for the joint-space inertia, which is tens of
rows, not thousands.

| File | Responsibility |
| --- | --- |
| `kn_math.hpp` | vectors, quaternions, transforms, dense LDLᵀ |
| `kn_spatial.hpp` | 6D motion/force vectors, spatial inertia, cross products |
| `kn_model.hpp` | geoms, joints, links, articulations, actuators, sensors |
| `kn_dynamics.cpp` | forward kinematics, CRBA, RNEA, mass factorisation |
| `kn_collision.cpp` | analytic pairs, GJK/EPA, manifolds, SAP broadphase, rays |
| `kn_solver.cpp` | constraint assembly and the PGS sweep |
| `kn_world.cpp` | the step pipeline, integration, sensors, queries |
| `kn_threads.hpp` | a deterministic parallel-for |
| `kn_api.cpp` | the C ABI implementation |

## The step pipeline

Every call to `step()` runs the same ten stages, and every stage is timed
individually and reported through `world.profile`.

```text
 1  forwardKinematics        link poses, spatial velocities, world inertias
 2  compositeRigidBodyInertia    joint-space inertia M                (CRBA)
 3  inverseDynamicsBias      Coriolis + centrifugal + gravity         (RNEA)
 4  applyForces              actuators, springs, damping, external wrenches
 5  factorMass               LDLᵀ of M, with implicit damping folded in
 6  unconstrainedAcceleration    a_free = M⁻¹ (τ − c)
 7  collide                  broadphase → narrowphase → manifolds
 8  buildConstraints         contacts, joint limits, equalities, friction
 9  solveConstraints         projected Gauss-Seidel with warm starting
10  integrate                semi-implicit Euler (or RK4) on the manifold
```

Reading `world.profile` after a step tells you which stage a slow scene is
spending its time in, which is almost always either `collision` or `solve`.

## Threading

Only one stage is parallel: the narrowphase, where each candidate pair is
independent. Results are written into pre-sized per-pair slots and merged by the
caller in index order, so the parallel and serial paths produce **bit-identical**
output. That property is asserted by `kinetic validate`.

Everything else is single-threaded on purpose. The solver is a Gauss-Seidel
sweep, which is sequential by construction; parallelising it would mean either
Jacobi iterations (slower convergence) or graph colouring (non-deterministic
ordering). Neither trade is worth it at the scene sizes Kinetic targets.

## Kinetic (Swift)

The Swift layer is value-typed. `Shape`, `JointSpec`, `SurfaceMaterial`,
`Appearance`, `Pose` are all structs; `World` is the single reference type,
because it owns the C handle.

It also contains everything that is easier to write in Swift than in C++:
XML parsing for URDF and MJCF (Foundation's `XMLDocument`), mesh decoding,
Quickhull, and the `.kinlog` container.

## KineticRender

A forward renderer, not deferred: the scene is a few hundred instanced
primitives, so the G-buffer bandwidth would cost more than it saves.

Shaders are compiled from source at runtime. SwiftPM has no first-class Metal
compilation step, and shipping a prebuilt `.metallib` would mean the package
builds differently under `swift build` than under Xcode. Runtime compilation
costs a few milliseconds once, at startup.

## KineticBridge

A hand-written RFC 6455 server on Network.framework TCP, plus the Foxglove
WebSocket protocol on top. Written by hand rather than layered on
`NWProtocolWebSocket` because subprotocol negotiation — which the Foxglove
handshake requires — and per-connection backpressure both needed to be under
direct control.

## Where state lives

The C++ `World` owns everything. Swift's `World` holds a pointer and exposes the
state vectors as `UnsafeMutableBufferPointer`, so reading `world.positions[2]`
is a load from engine memory, not a copy.

This is deliberate: a controller running at 500 Hz should not allocate. It also
means the buffers are invalidated by `compile()`, so never hold one across a
model change.
