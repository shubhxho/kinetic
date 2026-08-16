# On-device machine learning

Kinetic's ML runs on the same GPU the viewport is already using, through
[MLX](https://github.com/ml-explore/mlx-swift). There is no Python in the loop,
no separate process, and no serialisation boundary between the simulator and the
learner.

Three features use it, and each one is designed to work — in a reduced but honest
form — when it is not available:

| Feature | With MLX | Without |
| --- | --- | --- |
| [Learned control](./policies.md) | a neural policy trained by CEM | an analytic LQR baseline, which is already good |
| [Telemetry insight](./insights.md) | seven statistical detectors plus a learned joint-pattern mode | the seven statistical detectors |
| [Scene language](./language.md) | optional model-assisted parsing | the deterministic grammar, which is the default anyway |

## Availability is three states, not two

```swift
MLRuntime.isAvailable        // a GPU kernel actually ran
MLRuntime.isUsable           // MLX works at all, GPU or CPU
MLRuntime.deviceDescription  // "Apple GPU (applegpu_g16g), 16 GB unified memory"
try MLRuntime.requireBackend()
```

This distinction is not pedantry. MLX ships its kernels as Metal source compiled
by Xcode's build rule, and **`swift build` has no Metal compilation step** — so a
command-line build produces no `default.metallib` and MLX cannot initialise a
device at all, not even on CPU.

Consequences, stated plainly:

- A Studio app built by `Scripts/bundle-app.sh` reports the accelerator
  unavailable unless a metallib is present. The script stages one from
  DerivedData when it finds one and tells you when it cannot.
- Building or opening the package **in Xcode** gives you the GPU.
- `swift test` cannot exercise the neural paths for the same reason, which is why
  the ML tests assert the fallbacks rather than pretending.

Reporting CPU-only as "unavailable" would have been a lie; reporting it as GPU a
worse one. Hence three states.

## Determinism

Kinetic's whole value proposition is that the same inputs produce the same
outputs, and the ML does not get an exemption:

```swift
MLRuntime.seed(0x5EED)
```

Every random draw in `KineticML` — batch order, CEM sampling, rollout
perturbations, placement jitter — comes from a seeded generator owned by the
code that needs it. Nothing calls `Int.random`, `Double.random` or the system
generator. A training run repeats bit-identically from the same seed.

MLX parameter dictionaries are flattened with sorted keys, so a checkpoint is
byte-stable and therefore diffable in git.

## The precision boundary

The physics core is double precision throughout; MLX stores float32. The
conversion is explicit and named:

```swift
MLTensorBridge.storageDType    // .float32
MLTensorBridge.vector([Double]) -> MLXArray
MLTensorBridge.doubles(MLXArray) -> [Double]
```

This is safe here because a learning signal does not need f64 — a policy
gradient at 1e-7 relative precision is noise-dominated long before it is
precision-dominated. It would **not** be safe to run the dynamics there, which is
why the boundary is a bridge and not a build flag.

## Networks and checkpoints

```swift
let spec = MLPSpec(inputSize: 4, hiddenSizes: [8], outputSize: 1,
                   activation: .tanh, outputSquash: .tanh(low: -1, high: 1))
let net = try MLP(spec: spec)
let action = net.predict([x, dx, theta, dtheta])
try net.save(to: url)
```

Checkpoints are JSON — the spec plus flattened weights, sorted, pretty-printed.
A trained policy can be committed to a repository, read by a human, and loaded
with no extra dependency.

## Training

```swift
// Supervised, differentiable: Adam on MSE.
let losses = try Trainer.fitRegression(model: net, inputs: xs, targets: ys,
                                       config: TrainingConfig())

// Non-differentiable: the objective runs a physics rollout.
let parameters = Trainer.crossEntropyMethod(
    spec: spec,
    evaluate: { candidate in runEpisode(candidate) },
    parameterCount: spec.parameterCount,
    iterations: 60, population: 64, eliteFraction: 0.2, seed: 0x5EED)
```

The second is the one that matters for control. A contact impulse is not a
differentiable function of the policy parameters, so gradient methods do not
apply to a rollout that touches the ground. CEM fits a diagonal Gaussian over the
parameter vector from the elite samples — which means its sample requirement
scales with dimension, and that is exactly why the default policy is small.
