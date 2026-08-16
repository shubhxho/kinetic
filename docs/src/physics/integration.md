# Integration and determinism

## Semi-implicit Euler (default)

```text
v ← v + h · a
q ← q ⊕ h · v
```

Velocity first, then position using the *new* velocity. First-order accurate,
but symplectic-like: it does not pump energy into oscillators the way explicit
Euler does, which is why an undamped pendulum drifts 0.2% over ten seconds
instead of exploding.

It is also unconditionally the right choice when contacts are active, because
constraint impulses are not differentiable and an intermediate-stage evaluation
of them means nothing.

Position updates go through the manifold, not a raw vector add:

- revolute and prismatic joints add \\(h\\dot q\\) and clamp to their limits;
- spherical and free joints use an exponential map,
  \\(q \\leftarrow \\exp(\\omega_{\\text{local}} h) \\otimes q\\), then
  renormalise.

The angular velocity is rotated into the joint frame before the update, so a
spherical joint on a moving parent integrates correctly.

## Runge-Kutta 4

```swift
var options = world.options
options.integrator = .rungeKutta4
world.options = options
```

Classical RK4 over the smooth dynamics, with each stage's position update going
through the same manifold integrator so quaternions stay unit at every stage.

**It falls back to Euler on any step where a constraint is active.** Evaluating
contact impulses at intermediate stages would cost four solves for a result no
more accurate than the first-order update, since the impulse is a
non-differentiable function of state.

Where it earns its cost is torque-free rotation. The gyroscopic term
\\(\\omega \\times I\\omega\\) is what makes an asymmetric body tumble, and
first-order Euler handles it poorly:

| Integrator | Angular-momentum drift, 8 s of tumbling |
| --- | --- |
| semi-implicit Euler | 2.42% |
| RK4 | 0.0008% |

Use RK4 for ballistics, free-flying bodies, spacecraft and long-horizon
trajectory integration. Leave it off for anything that touches the ground.

## Velocity limits and damping

Velocities are clamped to `maxVelocity` (1000 m/s or rad/s by default) and any
non-finite value is zeroed. This is a backstop against a numerically broken
model, not a modelling feature.

Global `linearDamping` and `angularDamping` apply only to free joints, as a
multiplicative decay per step. Prefer per-joint `damping` for articulated
mechanisms — it is integrated implicitly and therefore unconditionally stable.

## Determinism

Kinetic is deterministic in a strong sense: **the same build, given the same
inputs, produces bit-identical output**, including with the threaded narrowphase
enabled. Both are asserted by `kinetic validate` and by the test suite.

The things that make that true:

- **No fast-math.** The core is compiled without reassociation, so floating-point
  operations happen in source order.
- **Ordered parallelism.** The narrowphase writes into pre-sized per-pair slots
  and the caller merges them in index order. No atomics touch the result path.
- **Total orderings everywhere.** The broadphase sort breaks ties on `isMin` and
  then on index. Constraint blocks are built in manifold order. Nothing iterates
  a hash map to produce simulation state.
- **A seeded PRNG.** Sensor noise comes from a per-world xoroshiro, never from a
  global generator.
- **Double precision throughout** the dynamics. Only the renderer drops to float.

What determinism does *not* survive: a different binary. Changing compiler
version, optimisation level or target architecture can change the last bit of a
fused multiply-add. Pin the toolchain if you need reproducibility across
machines.

## Choosing a timestep

The default is 2 ms (500 Hz).

| Scene | Suggested |
| --- | --- |
| manipulator, no contact | 4–10 ms |
| legged robot, walking | 1–2 ms |
| impacts, small parts, high stiffness | 0.5–1 ms |
| free flight with RK4 | 5–20 ms |

Contact stiffness scales with the timestep automatically through
`stiffnessTimeConstant`, so halving the step does not require re-tuning
materials. What *does* change is how far a fast body travels per step — which
speculative contacts handle, but a smaller step still resolves the impact more
finely.

## Save, restore, replay

```swift
let state = world.saveState()   // qpos, qvel and time as [Double]
world.step(1000)
world.loadState(state)          // exactly back where it was
```

This is the mechanism behind Studio's timeline: every step is snapshotted into a
rolling window, and scrubbing restores those states directly. Nothing is
re-simulated, so what you see is what happened.
