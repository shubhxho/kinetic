# Configuration

Kinetic has no config file and no cloud account. The knobs that exist are
environment variables, Studio Settings, CLI flags, and `SimulationOptions` on
the world. Flags beat environment variables, which beat compiled defaults.

Dump what the process will actually use:

```bash
kinetic config                              # macOS CLI
kinetic config --port 9000 --rate 60        # flags win
KINETIC_PORT=9000 kinetic config            # env wins over default
./Scripts/bench-core.sh --config            # KineticCore, no Swift needed
```

`kinetic config` never prints the contents of `GITHUB_TOKEN`, only `set` or
`unset`. Nothing in this chapter is a secret. Do not put a real GitHub token,
signing identity or API key in the tree.

## Environment

| Variable | Who reads it | Effect |
| --- | --- | --- |
| `GITHUB_TOKEN` | `ModelLibrary` fetch | Sent as `Authorization: Bearer …` on GitHub tree listings. Anonymous traffic is 60 requests an hour; a token raises that. Create a classic PAT with `public_repo` (or finer) and export it in the shell. Never commit it. |
| `KINETIC_DURATION` | `kinetic run` | Simulated seconds when `--duration` is omitted (default 5). |
| `KINETIC_PORT` | `kinetic run --serve`, `kinetic serve` | Telemetry listen port when `--port` is omitted (default 8765). Must be 1–65535. |
| `KINETIC_RATE` | `kinetic run --serve`, `kinetic serve` | Foxglove publish rate in Hz when `--rate` is omitted (default 30). Must be greater than 0. |
| `KINETIC_SERIAL` | `kinetic run`, `bench`, `serve`; `kinetic-core-bench` | If the variable is present at all, the narrowphase runs single-threaded. Same presence rule as `KINETIC_AUTOPLAY`. |
| `KINETIC_BENCH_SECONDS` | `kinetic bench`, `kinetic-core-bench` | Simulated seconds per scene when `--seconds` is omitted (CLI default 2, core-bench default 1). |
| `KINETIC_AUTOPLAY` | Kinetic Studio, on appear | If the variable is present at all, playback starts at launch. Used to profile a running window without driving the transport from the UI. |

A shape-only example:

```bash
export GITHUB_TOKEN=ghp_example_not_a_real_token
kinetic models fetch unitree-go2
```

If fetch returns HTTP 403 or 429, the error text already tells you to set
`GITHUB_TOKEN`. `kinetic config` reports the token as `set` without echoing it.

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

Stored in `UserDefaults` / `@AppStorage`, not in a file you edit. The
preferences window writes these keys; the running app reads them.

| Key | Default | Meaning | When it applies |
| --- | --- | --- | --- |
| `studio.telemetryPort` | `8765` | Foxglove WebSocket listen port | next time you start the telemetry server |
| `studio.publishRate` | `30` | Bridge publish rate, Hz | next time you start the telemetry server |
| `studio.historySeconds` | `20` | Timeline state window | immediately (resizes the ring buffer) |
| `studio.viewportFrameRate` | `120` | Display link while playing | immediately |
| `studio.pausedFrameRate` | `30` | Display link while paused | immediately |
| `studio.panels.layout.v1` | Simulate preset | Binary-split panel tree, JSON | on launch, and when you save a layout |

A decode failure of the layout key falls back to the Simulate preset rather
than crashing. Bump the suffix if the tree shape ever changes. Changing the
listen port does not restart a server that is already bound.

## CLI flags that change behaviour

`kinetic config` and `kinetic-core-bench --config` print the resolved value
and which layer supplied it (`--flag`, `KINETIC_*`, or `default`).

| Flag | Commands | Default | Also from |
| --- | --- | --- | --- |
| `--duration <s>` | `run` | 5 simulated seconds | `KINETIC_DURATION` |
| `--steps <n>` | `run`, `render` | from duration / timestep, or 0 for render | |
| `--realtime` | `run` | off (run as fast as the machine can) | |
| `--record <path>` | `run` | off | |
| `--serve` | `run` | off | |
| `--port <n>` | `run --serve`, `serve` | 8765 | `KINETIC_PORT` |
| `--rate <hz>` | `run --serve`, `serve` | 30 | `KINETIC_RATE` |
| `--serial` | `run`, `bench`, `serve`, `kinetic-core-bench` | off (threaded narrowphase) | `KINETIC_SERIAL` |
| `--seconds <s>` | `bench`, `kinetic-core-bench` | 2 for `kinetic bench`; 1 for `bench-core.sh` | `KINETIC_BENCH_SECONDS` |
| `--check` | `kinetic-core-bench` | off (print a table only) | |
| `--json` | `kinetic-core-bench` | off (human table) | |
| `--config` | `kinetic`, `kinetic-core-bench` | dump resolved knobs and exit | |
| `--out`, `--width`, `--height`, `--light`, `--no-contacts` | `render` | `kinetic-frame.png`, 1600×1000, dark, contacts on | |
| `--csv <path>` | `replay` | off | |

`--rate` on `kinetic run --serve` is the same knob as `kinetic serve --rate`.
`--serial` on `run` and `serve` is the same knob as `kinetic bench --serial`:
it sets `world.options.multithreaded = false`.

An invalid flag value (`--seconds 0`, `--port abc`, `--duration -1`) exits
non-zero. An invalid environment value is ignored and the compiled default
wins. `KINETIC_SERIAL` is presence-based: an empty value still means serial.

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
