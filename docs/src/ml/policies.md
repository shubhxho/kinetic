# Learned control

The **Policy** panel in Studio trains a neural controller against a Kinetic scene
and measures it against an analytic baseline. The task that ships is cart-pole
balancing.

## Running one

```swift
let trained = try CartPoleTrainer.train(iterations: 60, population: 64,
                                        seed: 0x5EED) { iteration, score in
    print(iteration, score)
}

let metrics = CartPoleTrainer.evaluate(trained.makePolicy(),
                                       episodes: 25, seed: 0xC0FFEE)
// (meanSteps, meanReward, successRate)
```

`TrainedPolicy` is `Codable` — spec, flat parameters, and the metrics it
achieved — so a result can be committed as JSON and loaded instantly.

## The harness is task-agnostic

```swift
protocol Policy: Sendable {
    var observationSize: Int { get }
    var actionSize: Int { get }
    func action(observation: [Double]) -> [Double]
}

let runner = PolicyRunner(world: world, policy: policy,
                          observation: CartPole.observation,
                          apply: CartPole.apply)
let reward = runner.run(steps: 1000, reward: CartPole.reward)
```

Nothing cart-pole-specific lives in `PolicyRunner`. `CartPole` holds the task
definition — observation, action mapping, reward, termination — in one place, and
a new task is a new enum of the same shape.

## Reward shaping, and why

\\[ r = 1 - 0.50\\left(\\frac{\\theta}{0.7}\\right)^2
        - 0.25\\left(\\frac{x}{2.2}\\right)^2
        - 0.05u^2 \\]

bounded in [0.2, 1] while alive, credited only for non-terminal states.

A pure alive bonus is the honest objective but it is nearly flat: early in a CEM
run almost every candidate falls at the same time, so the elite set is chosen
from a tie and the search wanders. Each penalty is normalised by the value at
which the episode actually ends, which makes the weights directly comparable and
keeps the total positive while alive.

- The θ term is the task, and it separates "nearly upright" from "leaning but not
  yet failed".
- The x term stops a constant-velocity drift scoring the same as balancing.
- The small effort term discourages the full-scale chatter that gradient-free
  search loves, without ever making falling over preferable.

Measured discrimination: the LQR baseline scores 998.2, a do-nothing policy
267.4.

## The analytic baseline

`LQRCartPole` is a hand-derived linear feedback law, and it exists for two
reasons: the feature works with no accelerator at all, and a learned controller
that cannot beat a hand-derived linear law is worth knowing about.

Its gains were derived by solving the continuous algebraic Riccati equation for
the plant linearised about upright, with parameters **read out of the scene**
rather than assumed:

| quantity | value |
| --- | --- |
| cart mass (including slide armature) | 2.698 kg |
| pole mass, pivot to centre of mass | 0.4 kg, 0.3 m |
| pole inertia about the pivot | 0.05002 kg·m² |
| damping | 0.1 N·s/m slide, 0.002 N·m·s hinge |
| actuator | F = 50·u N |

\\[ u = \\text{clamp}(1.0000\\,x + 1.6280\\,\\dot x + 8.6712\\,\\theta + 1.9254\\,\\omega,\; -1,\; 1) \\]

Closed-loop poles −46.6, −2.80 ± 0.77j, −1.07. The easy check is
\\(k_x = \\sqrt{q_x/R} = 1.0000\\) exactly.

It survives 25/25 episodes at full length, recovers from initial angles up to
about 0.6 rad — past the task's own 0.7 rad failure threshold — and tolerates 2×
cart mass, ±50% pole mass, 30% gear loss and 5× damping. `Q = diag(1,1,10,1)` was
chosen over more aggressive tunings specifically because it had the smallest peak
cart excursion and the fewest saturated steps under all of those mismatches.

> It is linearisation-derived: near-upright only, no swing-up, and a bounded
> recoverable set under |u| ≤ 1.

## What CEM can and cannot do here

The default policy is 4 → 8 → 1, 49 parameters, tanh-squashed to the control
range. That is deliberately small: CEM fits a diagonal Gaussian over the whole
parameter vector from a handful of elites, so a 2×16 hidden network at 369
parameters would need populations in the hundreds before the elite statistics
mean anything.

Honest limits, which are also written into the doc comments:

- no temporal credit assignment — the whole episode gets one score;
- it optimises the mean over a **fixed** set of initial perturbations, and
  therefore overfits that set, which is why `evaluate` re-scores on a different
  seed;
- it is a local search, so a bad seed can converge to a mediocre basin.
