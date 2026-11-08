# Install

Kinetic Studio and `kinetic render` run on macOS 14 or later with a Metal 3
GPU. That is what `Package.swift` declares (`platforms: [.macOS(.v14)]`,
`swift-tools-version: 6.0`). The CLI physics commands (`validate`, `run`,
`bench`, `info`, `list`) need the same OS and Swift toolchain, not a GPU.

A current `swift build` needs more than that, because the pinned MLX dependency
does:

| | Declared | Needed today |
| --- | --- | --- |
| OS | macOS 14+ | macOS 14+ to run |
| SwiftPM | 6.0 | **Swift 6.3** |
| Xcode | (unspecified) | **Xcode 26** on the project's CI |

[mlx-swift 0.31.x](https://github.com/ml-explore/mlx-swift) (this tree pins
`0.31.6`) declares `swift-tools-version: 6.3`. Swift 6.1 on a macOS 15 image
refuses to read that manifest, which is why CI (`.github/workflows/ci.yml`)
runs on `macos-26`.

Check what you have:

```bash
swift --version      # Apple Swift 6.3 or newer, for a current mlx-swift pin
xcodebuild -version  # Xcode 26 on CI; older Xcode will fail at package resolution
```

`mlx-swift` is a root `Package.swift` dependency. SwiftPM parses it before it
builds any product, so a consumer that links only `Kinetic` still needs Swift
6.3. Omitting `KineticML` does not skip that toolchain.

## Build from source

```bash
git clone https://github.com/shubhxho/kinetic
cd kinetic
swift build -c release
```

That produces two executables in `.build/release`:

| Binary | What it is |
| --- | --- |
| `kinetic` | the command-line tool |
| `KineticStudio` | the app's raw executable |

## First successful simulation

Do this before Studio. It does not need Metal.

```bash
./.build/release/kinetic validate
./.build/release/kinetic list
./.build/release/kinetic config
./.build/release/kinetic run stack --duration 1
```

`validate` exits 0 only if every closed-form check passes.
`list` prints the seven built-in scene ids (`stack`, `arm`, `quadruped`,
`cartpole`, `chain`, `dominoes`, `mixed`).
`run stack --duration 1` steps the ten-box tower for one simulated second and
prints realtime factor, step cost, contacts and energy. That is a completed
simulation.

The transcript below is from a macOS release build of `kinetic validate`. It
was not re-run in the Linux documentation checkout, which has g++ but no Swift.

```text
Physics validation

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

Every one of those is a closed-form or conservation-law comparison, not a
smoke test. [Accuracy and validation](../physics/accuracy.md) explains what each
one proves.

## Build the app bundle

`swift build` emits a bare executable. macOS needs an `Info.plist` and the usual
directory layout before a binary can own a Dock icon, a menu bar and keyboard
focus, so a script assembles one:

```bash
./Scripts/bundle-app.sh release
open "dist/Kinetic Studio.app"
```

The script also copies the SwiftPM resource bundles next to the executable and
into `Contents/Resources`, and applies an ad-hoc signature so Gatekeeper lets a
locally built app run.

## Put the CLI on your PATH

```bash
sudo ln -sf "$(pwd)/.build/release/kinetic" /usr/local/bin/kinetic
kinetic list
```

## Use Kinetic as a dependency

Add it to another Swift package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/shubhxho/kinetic", from: "1.0.0")
],
targets: [
    .target(name: "MyRobot", dependencies: [
        .product(name: "Kinetic", package: "kinetic"),          // physics
        .product(name: "KineticRender", package: "kinetic"),    // Metal viewport
        .product(name: "KineticBridge", package: "kinetic"),    // telemetry server
        .product(name: "KineticML", package: "kinetic"),        // optional, pulls mlx-swift
    ])
]
```

The products are separable at link time. `Kinetic` alone has no GUI dependency
and is safe to link into a headless tool or a test target. Swift 6.3 is still
required for any product in this package, because `mlx-swift` is declared at
the root of `Package.swift` and SwiftPM reads that manifest first.

## Run the tests

```bash
swift test
```

53 tests across ten suites: dynamics, kinematics, constraints, the convex hull,
mesh import, URDF, MJCF, the recording format, the WebSocket transport, and
benchmarks. The benchmark suite times every built-in scene, then asserts
invariants that do not depend on the host clock (published nv/geom counts,
contact character, cost ordering, determinism). It does not assert the M4
milliseconds-per-step table.

The physics core also has a compiler-only gate that runs without Swift. On
Linux that is the first successful run this tree can actually execute:

```bash
./Scripts/bench-core.sh --check --seconds 1
```

It compiles KineticCore with g++ or `$CXX` and asserts scene sizes, contact
character, cost ordering, stack stability and bit-identical serial vs
threaded runs. Absolute ms/step is printed. It is not the M4 table.

## Build the documentation

This book is [mdBook](https://rust-lang.github.io/mdBook/):

```bash
brew install mdbook
mdbook serve docs --open
```

CI and Vercel both run `./Scripts/build-docs.sh`, which installs mdBook v0.5.4
if needed, builds the book, and checks internal links.

## Host the book

The simulator stays on the Mac. The book is static HTML and can live in two
places at once:

**GitHub Pages** already publishes from `main` to
https://shubhxho.github.io/kinetic.

**Vercel** (Hobby is enough; no paid plan is required):

1. On [vercel.com/new](https://vercel.com/new), import `shubhxho/kinetic`.
2. Leave the preset as Other. `vercel.json` sets the build command to
   `./Scripts/build-docs.sh` and the output directory to `docs/book`.
3. Deploy. The site is the book at the domain root, not under `/kinetic/`.

Alternatively set a repository secret `VERCEL_TOKEN` (Vercel → Settings →
Tokens). `.github/workflows/vercel.yml` then deploys `docs/book` to a project
named `kinetic-docs`. Optional: `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` to pin
an existing project. The workflow is a no-op when the token is unset, so it
does not fail CI.

Do not put a Vercel token in the tree. A dummy
`VERCEL_TOKEN=vercel_example_not_a_real_token` is enough to describe the shape.

## Configuration

There is no config file. `kinetic config` dumps the resolved flags, environment
and defaults. Telemetry port, model cache, `GITHUB_TOKEN` and
`SimulationOptions` are documented in [Configuration](./configuration.md).
