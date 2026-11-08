# Benchmarks

Measured with `kinetic bench` on an Apple M4, macOS 26, release build, double
precision, warm caches. Each scene is warmed up before timing so first-touch page
faults do not land in the measurement.

```bash
kinetic bench
```

| Scene | nv | geoms | ms/step | steps/s | realtime | contacts |
| --- | --- | --- | --- | --- | --- | --- |
| cartpole | 2 | 3 | 0.0005 | 2,062,096 | 4124× | 0 |
| arm | 6 | 8 | 0.0015 | 680,728 | 1362× | 0 |
| chain | 20 | 21 | 0.0040 | 248,573 | 497× | 0 |
| quadruped | 18 | 18 | 0.0141 | 71,083 | 142× | 4 |
| stack | 60 | 11 | 0.0868 | 11,517 | 23× | 40 |
| mixed | 144 | 25 | 0.2380 | 4,201 | 8.4× | 100 |
| dominoes | 360 | 61 | 0.3948 | 2,533 | 5.1× | 282 |

"Realtime" is how many times faster than wall clock the scene runs at its own
timestep. A 12-actuator quadruped at 142× means a 10-second walking trial
finishes in 70 ms.

## Where the time goes

`world.profile` breaks each step down by stage. For `dominoes` at 282 contacts:

| Stage | Share |
| --- | --- |
| solve | ~62% |
| collide | ~21% |
| constraint setup | ~9% |
| inertia (CRBA) | ~4% |
| kinematics, bias, integrate, sensors | ~4% |

Contact-rich scenes are solver-bound; articulated scenes with few contacts are
bound by CRBA and the mass-matrix factorisation.

## Threading

Only the narrowphase is parallel. `--serial` disables it:

| Scene | serial | threaded | speed-up |
| --- | --- | --- | --- |
| mixed | 0.336 | 0.238 | 1.41× |
| stack | 0.111 | 0.087 | 1.28× |
| quadruped | 0.018 | 0.014 | 1.28× |

The gain is modest because collision is not the dominant stage in most scenes.
Both paths are **bit-identical** — asserted by `kinetic validate`.

## What changed in the physics rewrite

Speculative contacts, swept AABBs, the threaded narrowphase and making torsional
friction opt-in, measured against the same scenes:

| Scene | before | after | change |
| --- | --- | --- | --- |
| quadruped | 0.0533 | 0.0141 | 3.8× faster |
| mixed | 0.5474 | 0.2380 | 2.3× faster |
| stack | 0.0891 | 0.0868 | 1.03× faster |
| dominoes | 0.3794 | 0.3948 | 4% slower |

Dominoes pays a small amount for the swept bounds that make the tunnelling
guarantee possible. That is the intended trade.

Accuracy improved at the same time: resting penetration went from 0.5 mm to
0.0 mm, and a 120 m/s projectile now stops at a 10 mm wall instead of passing
through it.

## Rendering

The viewport draws one instanced call per mesh type per pass, plus a shadow pass,
a grid pass and a resolve.

| Scene | instances | draw calls | draw time |
| --- | --- | --- | --- |
| stack | 10 | 6 | 0.35 ms |
| dominoes | 60 | 6 | 0.41 ms |
| quadruped | 17 | 8 | 0.38 ms |

At 120 Hz the frame budget is 8.3 ms, so the viewport is not the constraint for
any scene here.

## Tests

Two gates share the `SceneLibrary` geometries and the same warmup-then-time
protocol as `kinetic bench`. Neither asserts the M4 milliseconds-per-step
table above.

| Gate | Runs on | What it asserts |
| --- | --- | --- |
| `Tests/KineticTests/BenchmarkTests.swift` | macOS, `swift test` | published nv/geoms; finite timed runs; contact-free vs contact-rich; articulated scenes cheaper than piles; serial vs threaded bit-identity; profile stages; stack still stacked |
| `./Scripts/bench-core.sh --check` | any OS with g++ or `$CXX` | the same invariants through `kinetic.h`, plus `kinetic validate`'s stack / determinism / threaded-narrowphase checks |

CI runs both: `swift test` on `macos-26`, `bench-core.sh --check --seconds 1`
on `ubuntu-latest`.

## Linux KineticCore (this checkout)

Verified here, not on the M4. `g++ 13.3.0 -O2`, Linux x86_64, 4 cores, Kinetic
1.0.0, 2.0 s of simulated time per scene, 50-step warmup, threaded
narrowphase. The harness rebuilds each scene through `kinetic.h`; nv and geom
counts match the table above. Absolute ms/step is a different ISA and a
different compiler, so it is **not** comparable to the M4 column.

```bash
./Scripts/bench-core.sh --check --seconds 1
./.build/kinetic-core-bench --seconds 2
```

`--check` reported 41 passes, including stack stability (max drift 4.85 mm),
168-coordinate determinism, and 420-coordinate threaded-narrowphase
bit-identity.

| Scene | nv | geoms | ms/step | steps/s | realtime | contacts |
| --- | --- | --- | --- | --- | --- | --- |
| cartpole | 2 | 3 | 0.0011 | 941,508 | 1883× | 0 |
| arm | 6 | 8 | 0.0026 | 379,471 | 759× | 0 |
| chain | 20 | 21 | 0.0073 | 137,653 | 275× | 0 |
| quadruped | 18 | 18 | 0.0202 | 49,608 | 99× | 4 |
| stack | 60 | 11 | 0.0994 | 10,058 | 20× | 40 |
| mixed | 144 | 25 | 0.1942 | 5,150 | 10× | 58 |
| dominoes | 360 | 61 | 0.4831 | 2,070 | 4.1× | 282 |

Serial vs threaded on the same guest, 2.0 s simulated:

| Scene | serial | threaded | speed-up |
| --- | --- | --- | --- |
| mixed | 0.2848 | 0.1942 | 1.47× |
| stack | 0.1002 | 0.0994 | 1.01× |
| quadruped | 0.0202 | 0.0202 | 1.00× |
| dominoes | 0.4640 | 0.4831 | 0.96× |

Threading helps the mixed pile, where collision is a larger share of the step.
On this 4-core guest the other scenes are inside the noise, and dominoes is
slightly slower threaded. Both paths stayed bit-identical.

`swift test` / `kinetic bench` were **not** run here: this environment has no
Swift toolchain and no Metal.

## Methodology and honesty

- Single machine, single configuration. Numbers on Intel Macs will differ.
- The Linux table is a second machine, not a rerun of the first.
- Double precision throughout the dynamics. Switching to float would be faster
  and is not offered, because determinism and energy behaviour matter more.
- These are **single-world** numbers. Kinetic does not vectorise across parallel
  environments. If you need thousands of environments stepping together, use a
  GPU-batched simulator; see [How Kinetic compares](./comparison.md).

Reproduce the M4 table with:

```bash
swift build -c release
./.build/release/kinetic bench --seconds 5
./.build/release/kinetic bench --serial --seconds 5
```

Reproduce the Linux KineticCore table with:

```bash
./Scripts/bench-core.sh --check --seconds 1
./.build/kinetic-core-bench --seconds 2
./.build/kinetic-core-bench --serial --seconds 2
```
