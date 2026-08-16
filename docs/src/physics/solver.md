# The constraint solver

Contacts, joint limits, dry friction and loop closures are all solved together as
one velocity-level problem. This chapter is the part of the engine most worth
understanding, because almost every tuning knob lives here.

## The Delassus operator

Each constraint has a Jacobian \\(J\\) mapping generalised velocity to constraint
velocity. Stacking them, the effective inverse inertia seen by the constraint set
is

\\[ A = J M^{-1} J^{\\mathsf T} \\]

the Delassus operator. Kinetic never assembles \\(A\\) globally. Each block stores
its own rows, its own \\(B = M^{-1}J^{\\mathsf T}\\) (obtained by back-substituting
through the LDLᵀ that `factorMass` already computed), and its own small dense
\\(A\\) — 1×1 for a joint limit, 3×3 or 4×4 for a contact, 6×6 for a weld.

A block touches at most two articulations, and its Jacobian rows are stored
densely over just those articulations' degrees of freedom. For a contact between
two free bodies, that is two 3×6 blocks rather than two rows of a 360-wide global
matrix.

## Soft constraints

A hard velocity constraint with Baumgarte stabilisation makes contact stiffness
depend on mass, timestep and how you feel that day. Kinetic instead parameterises
contact behaviour physically, by a **time constant** and a **damping ratio**:

\\[
\\omega = \\frac{1}{\\max(t_c,\\, 2h)}, \\qquad
\\zeta = \\text{dampingRatio}
\\]

\\[
\\text{cfm} = \\frac{A_{nn}}{h\\,(2\\zeta\\omega + h\\omega^2)}, \\qquad
\\text{erp} = \\frac{h\\omega^2}{2\\zeta\\omega + h\\omega^2}
\\]

`cfm` is added to the block's diagonal and `erp` scales the position-error bias.
Because both are expressed relative to \\(A_{nn}\\), the resulting stiffness is
independent of the masses involved: a 1 g screw and a 1 t chassis get the same
settling behaviour from the same `stiffnessTimeConstant`.

The default is 20 ms with critical damping. Joint limits use a much stiffer
`2h`, because a joint limit that visibly gives is a bug, not a material property.

## Speculative contacts

This is the part that removes two classic failure modes at once.

A contact point carries a signed gap: positive `depth` means overlap, negative
means the surfaces are still apart. The normal-velocity target is

\\[
b_n = \\begin{cases}
\\operatorname{clamp}\\!\\left(\\dfrac{\\text{erp}}{h}\\,(d - s),\; 0,\; v_{\\max}\\right)
  & d > s \\quad \\text{(overlapping)} \\\\[2ex]
\\dfrac{d}{h} & d < 0 \\quad \\text{(still separated)} \\\\[2ex]
0 & \\text{otherwise}
\\end{cases}
\\]

where \\(s\\) is `penetrationSlop`.

The middle case is the interesting one. A point that is still 3 mm away is told
"you may approach at up to 3 mm per step, and no more". The body therefore lands
*exactly* on the surface:

- **No steady-state penetration.** A resting sphere sits at exactly its radius.
  Before speculative contacts the same test settled 0.5 mm into the floor.
- **No tunnelling.** Combined with the swept AABBs from the previous chapter, a
  projectile at 120 m/s — 240 mm of travel per step — stops dead at a 10 mm
  wall. Both are asserted by `kinetic validate`.

Restitution, when non-zero and the pre-step approach speed exceeds a threshold,
raises the target to \\(-e\\,v_n^{-}\\).

## Friction

Two tangential rows per contact, targeting zero relative tangential velocity,
with impulses bounded by the friction cone

\\[ \\sqrt{\\lambda_{t_1}^2 + \\lambda_{t_2}^2} \\le \\mu\\,\\lambda_n \\]

Kinetic projects onto the **true second-order cone**, not the four- or eight-sided
pyramid most solvers linearise to. A pyramid makes friction direction-dependent:
a box slides more easily along a diagonal than along an axis, which shows up as
objects curving as they slide. The cone projection is one square root and a
scale, and removes the artefact entirely.

Tangent directions are rebuilt each step from the normal with a branchless
orthonormal basis, and warm-start impulses are carried in that frame.

### Torsional friction

An optional fourth row resists spin about the contact normal, bounded by
\\(|\\lambda_\\tau| \\le \\mu_\\tau \\lambda_n\\) with \\(\\mu_\\tau\\) in metres.
Point friction cannot stop a sphere or a foot pivoting in place; this can.

It is **off by default** because it costs a fourth row on every contact — roughly
30% of solver time in a contact-heavy scene — and only matters for geometry that
actually pivots. Turn it on per material:

```swift
SurfaceMaterial(friction: 1.3, torsionalFriction: 0.012)   // a rubber foot
```

## Other constraint types

| Kind | Rows | Bounds |
| --- | --- | --- |
| contact | 3, or 4 with torsion | \\(\\lambda_n \\ge 0\\), friction cone |
| joint limit | 1 per violated side | \\(\\lambda \\ge 0\\) |
| joint dry friction | 1 | \\(|\\lambda| \\le f\\,h\\) |
| equality: connect | 3 | unbounded |
| equality: weld | 6 | unbounded |
| equality: joint lock | 1 | unbounded |

Joint limits activate within 30 mrad of the bound rather than exactly at it, so
the constraint is already present when the joint arrives instead of being
discovered after it has overshot.

## The sweep

Projected Gauss-Seidel. Each iteration walks the blocks in order; for each row it
computes the current constraint velocity, solves for the impulse change that
would zero the residual, clamps or cone-projects it, and immediately applies the
resulting velocity change:

```text
for iteration in 0 ..< (solverIterations + relaxationIterations):
    for block in blocks:
        vn ← J·(v* + Δv)
        δλ ← −(vn − bias) / A_nn
        λ  ← project(λ + δλ)
        Δv ← Δv + B·(λ_new − λ_old)
    if max|δλ| < tolerance: break
```

Applying each impulse immediately — rather than accumulating and applying at the
end, as Jacobi would — is what makes Gauss-Seidel converge in tens of iterations
instead of hundreds. It is also why the solver is not parallelised; see
[Architecture](../concepts/architecture.md).

Within a contact block the normal is solved before friction, so friction always
sees the current normal impulse when computing its bound.

## Degenerate constraints

A contact whose normal lies entirely in the nullspace of both bodies' Jacobians
has \\(A_{nn} = 0\\): no achievable motion can resolve it. Kinetic drops the row
rather than regularising it into a large, meaningless impulse.

This is a real situation, not a hypothetical — two links joined by revolute
joints whose axes cannot move them apart along the contact normal. The test suite
covers it explicitly.

## Tuning

| Symptom | Try |
| --- | --- |
| stack sinks or wobbles | more `solverIterations`; check `armature` is non-zero |
| contacts feel spongy | lower `stiffnessTimeConstant` toward `2 * timestep` |
| jitter at rest | raise `stiffnessTimeConstant`, or `dampingRatio` above 1 |
| objects slide when they should grip | raise `friction`; add `torsionalFriction` |
| a spinning object never stops | add `torsionalFriction` |
| solver residual stays high | scene is over-constrained, or masses differ by >10⁴ |

`world.profile.solverResidual` and `solverIterations` report what the sweep
actually did, and both are plottable channels in Studio.
