# Install

Kinetic runs on macOS 14 or later with a Metal 3 GPU. That is what
`Package.swift` declares (`platforms: [.macOS(.v14)]`, `swift-tools-version: 6.0`).

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

Confirm the engine is healthy before going further:

```bash
./.build/release/kinetic validate
```

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

The products are separable. `Kinetic` alone has no GUI dependency and is safe
to link into a headless tool or a test target. `KineticML` is the one that
pulls MLX and therefore the Swift 6.3 toolchain requirement.

## Run the tests

```bash
swift test
```

45 tests across nine suites: dynamics, kinematics, constraints, the convex hull,
mesh import, URDF, MJCF, the recording format and the WebSocket transport.

## Build the documentation

This book is [mdBook](https://rust-lang.github.io/mdBook/):

```bash
brew install mdbook
mdbook serve docs --open
```

CI installs the v0.5.4 Linux binary from the mdBook releases page and then
runs `mdbook build docs` plus `python3 docs/check-links.py docs/book`.

## Configuration

There is no config file. Telemetry port, model cache, `GITHUB_TOKEN` and
`SimulationOptions` are documented in [Configuration](./configuration.md).
