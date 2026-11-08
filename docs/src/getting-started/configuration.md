# Configuration

Kinetic has no config file and no cloud account. The knobs that exist are
environment variables, Studio Settings, CLI flags, and `SimulationOptions` on
the world.

Nothing in this chapter is a secret. Do not put a real GitHub token, signing
identity or API key in the tree.

## Environment

| Variable | Who reads it | Effect |
| --- | --- | --- |
| `GITHUB_TOKEN` | `ModelLibrary` fetch | Sent as `Authorization: Bearer …` on GitHub tree listings. Anonymous traffic is 60 requests an hour; a token raises that. Create a classic PAT with `public_repo` (or finer) and export it in the shell. Never commit it. |
| `KINETIC_AUTOPLAY` | Kinetic Studio, on appear | If the variable is present at all, playback starts at launch. Used to profile a running window without driving the transport from the UI. |

A shape-only example:

```bash
export GITHUB_TOKEN=ghp_example_not_a_real_token
kinetic models fetch unitree-go2
```

If fetch returns HTTP 403 or 429, the error text already tells you to set
`GITHUB_TOKEN`.

## On-disk cache

Fetched robot descriptions land in:

```text
~/Library/Application Support/Kinetic/Models/<id>/
```

`kinetic models cache` prints the path, the count and the size.
`kinetic models purge <id>` removes one entry; `kinetic models purge` removes
the directory. A 404 body or a rate-limit page is never promoted out of
staging: the description file must parse with the expected root element first.

Pass a custom location from code:

```swift
let library = ModelLibrary(cacheURL: URL(fileURLWithPath: "/tmp/kinetic-models"))
```

## Studio Settings (`⌘,`)

Stored in `UserDefaults` / `@AppStorage`, not in a file you edit.

| Key | Default | Meaning |
| --- | --- | --- |
| `studio.telemetryPort` | `8765` | Foxglove WebSocket listen port |
| `studio.publishRate` | `30` | Bridge publish rate, Hz |
| `studio.historySeconds` | `20` | Timeline state window |
| `studio.viewportFrameRate` | `120` | Display link while playing |
| `studio.pausedFrameRate` | `30` | Display link while paused |
| `studio.panels.layout.v1` | Simulate preset | Binary-split panel tree, JSON |

A decode failure of the layout key falls back to the Simulate preset rather
than crashing. Bump the suffix if the tree shape ever changes.

## CLI flags that change behaviour

| Flag | Commands | Default |
| --- | --- | --- |
| `--duration <s>` | `run` | 5 simulated seconds |
| `--steps <n>` | `run`, `render` | from duration / timestep, or 0 for render |
| `--realtime` | `run` | off (run as fast as the machine can) |
| `--record <path>` | `run` | off |
| `--serve` / `--port <n>` | `run`, `serve` | port 8765 |
| `--rate <hz>` | `serve` | 30 |
| `--serial` | `bench`, `kinetic-core-bench` | off (threaded narrowphase) |
| `--seconds <s>` | `bench`, `kinetic-core-bench` | 2 for `kinetic bench`; 1 for `bench-core.sh` |
| `--check` | `kinetic-core-bench` | off (print a table only) |
| `--json` | `kinetic-core-bench` | off (human table) |
| `--out`, `--width`, `--height`, `--light` | `render` | `kinetic-frame.png`, 1600×1000, dark |
| `--csv <path>` | `replay` | off |

`kinetic models` subcommands: `list`, `info`, `fetch`, `validate`, `cache`,
`purge`. See [The `kinetic` CLI](./cli.md).

## Simulation options

`world.options` is a `SimulationOptions` value you can read and write while the
world is compiled. Studio's inspector exposes a subset of the same fields.

| Field | Default | Notes |
| --- | --- | --- |
| `timestep` | `1/500` s | 2 ms |
| `integrator` | `.semiImplicitEuler` | `.rungeKutta4` for contact-free rotation |
| `gravity` | `(0, 0, -9.81)` | Z-up |
| `solverIterations` | 30 | PGS sweeps |
| `relaxationIterations` | 6 | |
| `solverTolerance` | `1e-10` | |
| `warmStart` | `true` | keep it on |
| `contactMargin` | 2 mm | speculative generation distance |
| `penetrationSlop` | 0.5 mm | |
| `maxCorrectionVelocity` | 3 m/s | lower if a pose explodes |
| `enableContacts` / `enableJointLimits` / `enableEqualities` | `true` | |
| `multithreaded` | `true` | narrowphase only; bit-identical with serial |

Contact feel lives on `SurfaceMaterial` (`stiffnessTimeConstant`,
`dampingRatio`, `friction`, `torsionalFriction`), not on `SimulationOptions`.
See [Materials](../concepts/materials.md).

## App bundle

```bash
./Scripts/bundle-app.sh release          # dist/Kinetic Studio.app
./Scripts/bundle-app.sh release --dmg    # plus a ULFO disk image
./Scripts/bundle-app.sh release --skip-build
```

The script copies `KineticStudio` and `kinetic` into the bundle, stages SwiftPM
resource bundles, optionally copies an MLX metallib from DerivedData, writes
`Info.plist`, renders an icon, and ad-hoc signs. It is not a Developer ID
signature and it is not notarised.

`dist/` is gitignored.

## Hosting the book (Vercel)

The book is static files. Vercel hosts those files; it does not run Studio or
the CLI.

| Secret | Required | Where |
| --- | --- | --- |
| `VERCEL_TOKEN` | for the GitHub Action only | GitHub repo secret, from Vercel → Settings → Tokens |
| `VERCEL_ORG_ID` | no | Vercel project settings, if you pin a project |
| `VERCEL_PROJECT_ID` | no | same |

Importing the GitHub repo in the Vercel dashboard does not need those secrets:
Vercel builds from `vercel.json` on each push to the linked branch. Hobby is
enough. Do not commit `.vercel/` or a real token. A dummy
`VERCEL_TOKEN=vercel_example_not_a_real_token` is the documented shape.
