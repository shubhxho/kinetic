# Contributing

## Layout

```text
Sources/
  KineticCore/       C++20 physics; include/kinetic.h is the public ABI
  Kinetic/           Swift API, importers, meshes, hulls, recording
  KineticRender/     Metal renderer and the MTKView host
  KineticBridge/     WebSocket server and the Foxglove protocol
  KineticCLI/        the kinetic command
  KineticStudio/     the SwiftUI app
Tests/KineticTests/  44 tests across nine suites
docs/                this book
Scripts/             bundle-app.sh
```

## Building and checking

```bash
swift build -c release
swift test
./.build/release/kinetic validate
./.build/release/kinetic bench
```

All four must pass before a change lands. `validate` exits non-zero on failure,
so it works as a CI gate.

## Working on the physics core

The core has no dependencies and compiles standalone, which makes iteration fast:

```bash
cd Sources/KineticCore
clang++ -std=c++20 -Wall -Wextra -fsyntax-only -Iinclude -Isrc src/*.cpp
```

Rules that are not negotiable:

- **No fast-math, no reassociation.** Determinism depends on source-order
  floating point.
- **No unordered iteration in the simulation path.** Never iterate a hash map to
  produce state; sort or index first.
- **New parallel work must be order-independent.** Write into pre-sized slots and
  merge in index order, as the narrowphase does.
- **Double precision in the dynamics.** Float is for rendering only.

## Adding a collision pair

1. Write the routine in `kn_collision.cpp` producing points with the convention
   documented at the top of `kn_collision.hpp`: normal from B to A, positive
   depth when overlapping.
2. Dispatch to it in `collidePair`, with the flip helper if the canonical order
   is reversed.
3. Set `persistent` only if the routine can produce a single point per call.
4. Add a test that drops the shape on the ground and asserts where it rests.

## Adding a constraint type

1. Extend `ConstraintKind` in `kn_world.hpp`.
2. Build the block in `buildConstraints`: allocate, fill Jacobian rows, call
   `finalizeBlock`, set bias and bounds.
3. Handle its projection in the solver sweep if it is not a simple clamp.
4. Add a test asserting the constrained quantity.

## Adding a sensor

1. Add the case to `SensorType` in `kn_model.hpp` and `sensorDim`.
2. Implement it in `World::computeSensors`.
3. Mirror the enum in `kinetic.h` and `SensorKind` in `World.swift`.
4. The Studio channel picker and the bridge pick it up automatically from
   `sensorNames` and `sensorKinds`.

## Style

The code is written to be read.

- Comments explain **why**, never what. If a line needs a comment to say what it
  does, rename something instead.
- Document non-obvious trade-offs where they are made, not in a design doc.
- Match the surrounding code's density and idiom.
- Public API gets doc comments; internals get prose where the reasoning is
  non-local.

## Tests

Every test asserts against a closed form, a conservation law, or a documented
invariant. "It did not crash" is not a test.

If a test fails, work out whether the *test* is wrong before changing the engine
— two of the three failures during development were incorrect expectations, and
the third was a real bug the test found.

## Documentation

This book is mdBook:

```bash
mdbook serve docs --open
```

Chapters live in `docs/src`, the table of contents in `docs/src/SUMMARY.md`.
Numbers quoted in the docs come from `kinetic bench` and `kinetic validate` —
update them when the numbers change, and say what changed.
