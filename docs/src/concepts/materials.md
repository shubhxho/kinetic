# Materials and contact behaviour

A `SurfaceMaterial` describes how a geom behaves when it touches something. When
two geoms meet, their materials combine:

| Property | Combination |
| --- | --- |
| `friction` | geometric mean, \\(\\sqrt{\\mu_a \\mu_b}\\) |
| `torsionalFriction` | geometric mean |
| `restitution` | maximum |
| `stiffnessTimeConstant` | maximum (the softer wins) |
| `dampingRatio` | maximum |
| `margin` | maximum |

The geometric mean for friction is the usual convention: a rubber pad on ice
should behave like ice, not like the average of rubber and ice.

## Presets

```swift
SurfaceMaterial.default    // μ = 1.0, no restitution
SurfaceMaterial.ice        // μ = 0.05
SurfaceMaterial.rubber     // μ = 1.4, e = 0.6, torsional 0.01
SurfaceMaterial.steel      // μ = 0.4, e = 0.2
```

## Friction

`friction` is the Coulomb coefficient bounding tangential impulse at
\\(\\mu \\lambda_n\\). Kinetic projects onto the true friction cone rather than a
pyramid, so grip is isotropic — a box slides the same along an axis and along a
diagonal.

Typical values:

| Pair | μ |
| --- | --- |
| ice on ice | 0.03–0.1 |
| steel on steel | 0.4–0.8 |
| rubber on concrete | 0.9–1.5 |
| robot foot on rubber mat | 1.0–1.4 |

## Torsional friction

Off by default. Point friction cannot resist spin about the contact normal, so a
sphere or a flat foot pivots freely in place. Torsional friction adds a fourth
solver row bounding spin impulse at \\(\\mu_\\tau \\lambda_n\\), with
\\(\\mu_\\tau\\) in metres — roughly the effective radius of the contact patch.

```swift
SurfaceMaterial(friction: 1.3, torsionalFriction: 0.012)   // a 12 mm patch
```

Enable it for feet, wheels and balls. Leave it off elsewhere: it costs about 30%
of solver time in a contact-heavy scene.

## Restitution

Fraction of approach velocity returned on impact, 0 (fully inelastic) to 1
(elastic). It only engages above a threshold approach speed, so resting bodies do
not buzz.

```swift
SurfaceMaterial(friction: 0.5, restitution: 0.7)   // drops 0.9 m, rebounds ~0.44 m
```

Restitution is not energy-exact for multi-contact impacts — no impulse-based
solver's is. For a chain of touching bodies the result is plausible rather than
derived from a coefficient-of-restitution model.

## Stiffness: time constant and damping ratio

This is the pair to reach for when contacts feel wrong.

```swift
SurfaceMaterial(friction: 1.0,
                stiffnessTimeConstant: 0.02,   // seconds
                dampingRatio: 1.0)
```

`stiffnessTimeConstant` is the exponential time constant of contact-error decay.
20 ms means penetration is corrected over roughly 20 ms.

Crucially it is **mass-independent**: the solver derives the actual stiffness
from the constraint's own effective inertia, so a 1 g screw and a 1 t chassis
settle identically from the same setting. See
[The constraint solver](../physics/solver.md).

| Want | Set |
| --- | --- |
| near-rigid contact | `2 * timestep` (the floor the solver clamps to anyway) |
| default, stable | `0.02` |
| soft, compliant (a foam pad) | `0.05`–`0.1` |
| less bounce during settling | `dampingRatio` above 1 |

## Margin

`margin` widens the band in which contacts are generated for that geom. The
global `contactMargin` (2 mm) already covers normal use; per-geom margin is for
thin shells that need more warning.

Margin does **not** make objects hover: speculative contacts allow approach up to
the remaining gap, so a body still lands exactly on the surface.

## Global options

```swift
var options = world.options
options.timestep = 1.0 / 1000
options.gravity = Vec3(0, 0, -1.62)     // the Moon
options.solverIterations = 40
options.relaxationIterations = 8
options.contactMargin = 0.002
options.penetrationSlop = 0.0005
options.maxCorrectionVelocity = 3.0
options.warmStart = true
options.multithreaded = true
world.options = options
```

| Option | Meaning |
| --- | --- |
| `solverIterations` | primary PGS sweeps |
| `relaxationIterations` | extra low-stiffness polish sweeps |
| `penetrationSlop` | overlap tolerated before correction pushes back |
| `maxCorrectionVelocity` | caps how fast a deep overlap is resolved, so a bad initial pose does not launch anything |
| `warmStart` | reuse last step's impulses; roughly 10× fewer iterations for a resting stack |
| `multithreaded` | parallel narrowphase; bit-identical to serial |

## Appearance

Purely visual, no effect on physics:

```swift
Appearance(color: Vec4(0.9, 0.4, 0.2, 1),
           metallic: 0.2,      // 0 dielectric, 1 metal
           roughness: 0.45,    // 0 mirror, 1 fully diffuse
           emissive: 0.0)
```

Colours are authored in sRGB and converted to linear before lighting.
