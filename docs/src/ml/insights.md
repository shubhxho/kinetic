# Telemetry insight

The detector watches a running simulation and says, in words, when something went
wrong and when. It is designed for the case where a controller misbehaves for
three frames somewhere in a ten-second run and you do not know where to look.

## Cost

`observeStep` over nine channels costs **~1.0 µs per step** — about 112 ns per
channel — at 2 kHz. Channel indices are resolved once at registration; the hot
path does no hashing, no allocation and no string formatting. Explanations are
built only when something actually fires, and only after the refractory check.

## What it detects

Seven statistical detectors, per channel, streaming:

| Kind | Fires when |
| --- | --- |
| `spike` | robust z-score exceeds the channel's threshold |
| `stall` | a channel that was varying stops moving |
| `drift` | a fast EWMA departs one-directionally from a 64× slower baseline |
| `oscillation` | baseline crossings at regular period *and* amplitude |
| `divergence` | non-finite, or geometric growth sustained over N steps |
| `constraintStress` | solver residual held above 1e-3 |
| `rangeViolation` | a sign, bound or monotonicity hint is broken |

Plus one learned mode, `jointPattern`: an autoencoder over a sliding window of
the whole channel vector, which catches *joint* anomalies no single channel would
— contact count normal, step time normal, but the two together are not. It is
gated on MLX availability and falls back with an explicit status
(`runtimeUnavailable`, `modelUnavailable`, `trainingFailed`) rather than silently.

## Hints make it specific rather than generic

```swift
detector.register(channel: "solver residual", hint: .solverResidual)
detector.register(channel: "com height", hint: .height)
```

A `ChannelHint` declares sign, monotonicity, bounds, unit, whether the channel is
heavy-tailed, whether it is expected to vary, a noise floor, per-kind thresholds,
a refractory period and a warm-up count. Presets exist for every channel Studio
plots.

The noise floor matters more than it sounds: solver residuals and contact counts
are heavy-tailed, and a plain z-score cries wolf on them constantly.

## Explanations name real knobs

```text
solver residual held above 0.001 for 1.05 s (now 0.004) while contact count was
282 and the sweep ran 30 iterations — the scene is over-constrained or the mass
ratio is extreme.
```

```text
joint 3 angle crossed its baseline 40 times in 500 ms — about 40 Hz at a steady
amplitude of 0.020 rad, holding rather than decaying. That is a limit cycle, not
convergence.
```

```text
wrist force sensor has not moved from 2.718 for 250 ms, after varying by about
9.86e-05 before that — the channel looks frozen rather than settled.
```

`TelemetryInsight.explain` continues into advice, drawn from
[the solver's tuning table](../physics/solver.md) and
[troubleshooting](../reference/troubleshooting.md) — `solverIterations`,
`relaxationIterations`, `armature`, `stiffnessTimeConstant`, `warmStart`, mass
ratio. It does not invent knobs that do not exist.

## Correlation

```swift
TelemetryInsight.correlate(samples)   // [(a, b, r)], strongest first
```

which is what lets the panel say "step time tracks contact count at r = 0.94".

## False positives were the hard part

A six-second run of pure noise across all nine solver channels produces **zero**
anomalies. Getting there took two rewrites:

- the first oscillation test looked at sign flips of the step-to-step delta,
  which calls every noisy channel a limit cycle. It now requires baseline
  crossings with half-cycles of at least three samples, plus regularity in
  *both* period and amplitude;
- the first z-score reported a real 3 mrad joint movement as "4358 standard
  deviations", because the baseline variance was essentially zero. The score
  denominator is now floored by the channel's declared noise floor.

Two honest consequences:

- chatter at the step rate is **not** reported. On a single channel it is not
  separable from noise, and the code says so rather than guessing.
- a step change in level is reported as a spike and then, about a second later,
  echoed as a drift while the slow baseline catches up. Continuous conditions use
  escalation gates — re-reported only when materially worse — so an ongoing
  problem yields a handful of entries rather than hundreds.

All EWMA gains are per-sample and tuned for 2 kHz. Sampling at 60 Hz requires
raising `ChannelHint.smoothing`, which is documented on the property.

## Run summary

```swift
let report = TelemetryInsight.summarise(anomalies: found, samples: channels)
print(report.headline)
```

```text
18 anomalies in 4.00 s of simulation, worst spike on contacts at t = 1.000 s.
Step time p50 1.079 ms, p95 1.091 ms, max 5.400 ms. Contacts averaged 221,
peaking at 282. Energy gained 4.5% over the run. contacts tracks solver residual
at r = 0.999.
```
