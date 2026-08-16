# Troubleshooting

## The model explodes on the first step

Almost always overlapping geometry in the initial pose. Deep overlap produces a
large corrective impulse.

- Check the rest pose in Studio with the simulation paused.
- Lower `maxCorrectionVelocity` (default 3 m/s) so recovery is gentler.
- If links legitimately overlap near a joint, that pair is already filtered —
  but grandparent/grandchild pairs are not. Turn self-collision off for that
  articulation, or set group masks.

## A legged robot collapses immediately

Position actuators default to a control input of zero, so every joint is driven
to zero regardless of the default pose. Seed the control vector after `compile()`:

```swift
world.setDefaultPose(articulation: robot, q: pose)
world.compile()
for (i, angle) in jointAngles.enumerated() { world.control[i] = angle }
```

## Contacts feel spongy

- Lower `stiffnessTimeConstant` toward `2 * timestep`.
- Raise `solverIterations`.
- Check for extreme mass ratios: above roughly 10⁴ between contacting bodies,
  every impulse solver shows compliance.

## Objects jitter at rest

- Raise `stiffnessTimeConstant` (softer contacts settle more quietly).
- Raise `dampingRatio` above 1.
- Add `armature` to the joints. This is the single most effective fix for a
  jittering articulated robot.
- Confirm `warmStart` is on.

## A stack drifts sideways

- Add `torsionalFriction` to the material if the bodies are pivoting.
- Raise `friction`.
- More `solverIterations` — a tall stack needs more sweeps to propagate load.

## A fast object passes through a wall

It should not; speculative contacts and swept bounds cover this, and
`kinetic validate` asserts it at 120 m/s. If it happens:

- Confirm both geoms are `collidable` and their group masks overlap.
- Confirm the wall is not a `.plane` positioned so the object starts on the far
  side — a plane is a half-space, and a body that begins behind it is already
  "inside".
- Reduce the timestep for extreme speeds.

## A joint will not move

- Is its type `.fixed`?
- Are the limits equal (`lower == upper`)?
- Is `damping` very large? Implicit damping is stable, so a large value
  silently freezes the joint instead of oscillating.
- Is there an actuator holding it at a target?

Use the **Joints** tab in Studio to drag it directly and see what stops it.

## URDF meshes do not appear

The mesh could not be resolved. Set `onWarning` to see the path that failed:

```swift
var options = URDFImportOptions()
options.packageRoots = [URL(fileURLWithPath: "/path/to/ros_ws/src")]
options.onWarning = { print("urdf: \($0)") }
```

COLLADA and glTF are rejected rather than approximated — convert to STL or OBJ.

## An imported robot floats away

A URDF's root link gets a free joint by default. To bolt it down:

```swift
var options = URDFImportOptions()
options.fixedBase = true
```

## Concave geometry does not behave

Kinetic collides convex shapes only; a concave mesh becomes its convex hull.
Decompose it into convex parts upstream and attach one geom per part.

## Energy grows over time

- Restitution above 1 is not physical.
- Very large timesteps push semi-implicit Euler past its stable range.
- For contact-free rotating bodies, switch to `.rungeKutta4`.

## Results differ between runs

They should not. If they do:

- The same binary? Determinism does not survive a toolchain or optimisation
  change.
- Are you seeding `control` from something time- or thread-dependent?
- File a bug with the scene — this is a real defect, and `kinetic validate`
  checks it on every run.

## Studio will not launch

```bash
./Scripts/bundle-app.sh release
open "dist/Kinetic Studio.app"
```

Running `.build/release/KineticStudio` directly gives no Dock icon or menu bar,
because macOS needs the bundle layout. If Gatekeeper objects, the script's
ad-hoc signature may not have applied — check its output.

## The viewport is black

- `Renderer(sampleCount:)` returns `nil` when there is no Metal device; Studio
  logs this and shows a message instead of a viewport.
- Over a remote session there may be no GPU. The CLI's `render` command works
  headless; the interactive viewport does not.

## Telemetry will not connect

- Is the port free? `lsof -i :8765`
- Foxglove must connect as **Foxglove WebSocket**, not "Rosbridge".
- The status bar shows the connected client count when a client attaches.
