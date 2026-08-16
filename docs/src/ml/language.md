# Scene language

Type what you want, see exactly what will happen, then decide.

```text
drop five 10 cm boxes from 2 metres onto ice
```

```text
Summary   Add 5 boxes and make the ground icy.
          · add 5 box bodies, 0.10 m, dropped from 2.00 m
          · set ground friction to 0.05
Confidence 100%
```

Nothing touches the world until **Apply**.

## Why the deterministic path is primary

A simulator whose selling point is reproducibility should not have a
non-reproducible front door. The grammar is the default and always runs; a model
backend is consulted only when grammar confidence is low, and its output is a
`ScenePlan` you still have to approve.

```swift
protocol IntentBackend {
    func parse(_ text: String) throws -> ParsedIntent?
}
```

`GrammarBackend` needs no model at all. `ModelBackend` takes an injected
`(String) async throws -> String` returning JSON that matches `ScenePlan`, so the
model provider is the caller's choice and never a build dependency.

## What the grammar handles

Every phrasing below parses at full confidence:

```text
drop 5 boxes from 2 m                  add ten 5cm spheres in a ring of radius 0.4
make the ground icy                    set gravity to the moon
gravity 0 0 -3.7                       gravity off
timestep 1ms                           500 hz
run for 3 seconds                      run 500 steps
stack 8 boxes                          put 2 cylinders in a tower
use rk4                                40 solver iterations
load the quadruped                     dominoes
add a dozen wooden crates in a stack   half a dozen boxes
twenty five 2cm balls in a ring        scatter 20 marbles over 2 m
add 16 boxes in a grid spaced 0.3 m    add 4 by 4 grid of boxes
add 4 boxes rotated 45 degrees         drop 3 heavy steel spheres from 1.5 m
ground friction 0.3                    add a frictionless floor
make the boxes bouncy                  push the boxes right with 8 n s
push everything up                     run for 3 minutes
set gravity to mars and add 4 boxes    timestep 2 ms and 60 solver iterations then run for 1 s
```

Units are handled properly: mm/cm/m/km, ms/s/min/hz/khz, degrees and radians,
kg/m³, N·s. Numbers may be words, including "twenty five", "a dozen" and "half a
dozen". Fifteen named gravity presets.

Material adjectives — icy, bouncy, sticky, frictionless, rubber, steel, slippery,
rough — map onto real `SurfaceMaterial` values.

## Failure is visible, not silent

Garbage returns nil: `asdkjh qwe zzz`, `!!!???`, empty, `-`.

Partial garbage returns a low-confidence plan with the leftovers listed:
`drop -5 boxes from -2 m` parses at 67%, `add 99999 boxes` at 82%, and the panel
shows exactly which words meant nothing.

Confidence is capped below 1 on purpose. Matching every word is not
understanding, and a parser that claims certainty is lying.

## Operations are typed and phased

```swift
enum SceneOperation {
    case addBodies(count: Int, shape: ShapeSpec, at: PlacementSpec,
                   material: MaterialSpec, density: Double)
    case addGround(friction: Double)
    case setGravity(Vector3)
    case setTimestep(Double)
    case setSolverIterations(Int)
    case setMaterial(target: TargetSpec, material: MaterialSpec)
    case applyImpulse(target: TargetSpec, direction: [Double], magnitude: Double)
    case loadScene(String)
    case setIntegrator(String)
    case run(seconds: Double)
    case reset
}
```

Each carries an `OperationPhase` — `.topology`, `.settings` or `.state` — and the
applier sorts by phase before running, because topology changes must happen
before `compile()` and state changes after. An ordering conflict is **reported**,
not silently applied to a broken world.

Placement is its own type with a seeded generator: height, grid, stack, ring or
scattered, each with jitter and yaw jitter. It draws a fixed number of values per
body, so changing the arrangement does not desynchronise the jitter stream and
the same command twice produces the same scene.

## Honest gaps

- **No post-compile geom mutation exists in the engine**, so `setMaterial` is a
  pre-compile rule that binds bodies added later in the same plan. It reports how
  many already-built bodies it cannot touch rather than pretending.
- **There is no impulse API**, so `applyImpulse` writes `Δv = J/m` directly into
  the free joint's linear degrees of freedom and re-runs forward kinematics.
- **`loadScene` cannot target an existing world** — `SceneLibrary` entries build
  and compile their own — so a load buried mid-plan throws instead of silently
  discarding the earlier operations.
