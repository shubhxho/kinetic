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

<div class="kn-figure">
<svg viewBox="0 0 720 250" role="img" aria-label="Speculative contact versus a hard contact" class="kn-svg">
  <style>
    .kn-svg .ground { stroke: currentColor; stroke-width: 1.6; opacity: 0.6; }
    .kn-svg .hatch { stroke: currentColor; stroke-width: 0.8; opacity: 0.22; }
    .kn-svg .body { fill: none; stroke: currentColor; stroke-width: 1.5; opacity: 0.75; }
    .kn-svg .bad { stroke: #ff4d4f; stroke-width: 1.6; fill: none; }
    .kn-svg .good { stroke: #0cce6b; stroke-width: 1.6; fill: none; }
    .kn-svg .gap { stroke: #0070f3; stroke-width: 1.3; }
    .kn-svg .h { fill: currentColor; font: 600 12px ui-sans-serif, system-ui, sans-serif; }
    .kn-svg .m { fill: currentColor; font: 400 10.5px ui-monospace, monospace; opacity: 0.6; }
    .kn-svg .blue { fill: #0070f3; font: 600 10.5px ui-monospace, monospace; }
    .kn-svg .red { fill: #ff4d4f; font: 600 10.5px ui-monospace, monospace; }
    .kn-svg .green { fill: #0cce6b; font: 600 10.5px ui-monospace, monospace; }
  </style>

  <text class="h" x="24" y="26">step n — still separated</text>
  <line class="ground" x1="24" y1="150" x2="220" y2="150"/>
  <g class="hatch">
    <line x1="30" y1="150" x2="20" y2="162"/><line x1="55" y1="150" x2="45" y2="162"/>
    <line x1="80" y1="150" x2="70" y2="162"/><line x1="105" y1="150" x2="95" y2="162"/>
    <line x1="130" y1="150" x2="120" y2="162"/><line x1="155" y1="150" x2="145" y2="162"/>
    <line x1="180" y1="150" x2="170" y2="162"/><line x1="205" y1="150" x2="195" y2="162"/>
  </g>
  <circle class="body" cx="120" cy="88" r="26"/>
  <line class="gap" x1="120" y1="114" x2="120" y2="150"/>
  <line class="gap" x1="112" y1="114" x2="128" y2="114"/>
  <line class="gap" x1="112" y1="150" x2="128" y2="150"/>
  <text class="blue" x="134" y="136">gap d &lt; 0</text>
  <text class="m" x="24" y="186">target: vₙ ≥ d / h</text>
  <text class="m" x="24" y="202">“approach at most the gap”</text>

  <text class="h" x="264" y="26">without it</text>
  <line class="ground" x1="264" y1="150" x2="460" y2="150"/>
  <g class="hatch">
    <line x1="270" y1="150" x2="260" y2="162"/><line x1="295" y1="150" x2="285" y2="162"/>
    <line x1="320" y1="150" x2="310" y2="162"/><line x1="345" y1="150" x2="335" y2="162"/>
    <line x1="370" y1="150" x2="360" y2="162"/><line x1="395" y1="150" x2="385" y2="162"/>
    <line x1="420" y1="150" x2="410" y2="162"/><line x1="445" y1="150" x2="435" y2="162"/>
  </g>
  <circle class="bad" cx="360" cy="128" r="26"/>
  <line class="bad" x1="334" y1="150" x2="386" y2="150" stroke-dasharray="3 3"/>
  <text class="red" x="264" y="186">sinks 0.5 mm and stays there</text>
  <text class="m" x="264" y="202">soft constraint equilibrium</text>

  <text class="h" x="504" y="26">with it</text>
  <line class="ground" x1="504" y1="150" x2="700" y2="150"/>
  <g class="hatch">
    <line x1="510" y1="150" x2="500" y2="162"/><line x1="535" y1="150" x2="525" y2="162"/>
    <line x1="560" y1="150" x2="550" y2="162"/><line x1="585" y1="150" x2="575" y2="162"/>
    <line x1="610" y1="150" x2="600" y2="162"/><line x1="635" y1="150" x2="625" y2="162"/>
    <line x1="660" y1="150" x2="650" y2="162"/><line x1="685" y1="150" x2="675" y2="162"/>
  </g>
  <circle class="good" cx="600" cy="124" r="26"/>
  <text class="green" x="504" y="186">rests at exactly its radius</text>
  <text class="m" x="504" y="202">penetration 0.000 mm</text>
</svg>
  <p class="kn-caption">The same rule that removes steady-state penetration also
  removes tunnelling: a point 240 mm away is told it may close 240 mm, and one
  step later it is told it may close whatever is left.</p>
</div>


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

<div class="kn-figure">
<svg viewBox="0 0 620 230" role="img" aria-label="Friction cone versus a linearised pyramid" class="kn-svg">
  <style>
    .kn-svg .axis2 { stroke: currentColor; stroke-width: 1; opacity: 0.4; }
    .kn-svg .cone { fill: #0070f3; fill-opacity: 0.10; stroke: #0070f3; stroke-width: 1.6; }
    .kn-svg .pyr { fill: #f5a623; fill-opacity: 0.10; stroke: #f5a623; stroke-width: 1.6; }
    .kn-svg .h2 { fill: currentColor; font: 600 12px ui-sans-serif, system-ui, sans-serif; }
    .kn-svg .m2 { fill: currentColor; font: 400 10.5px ui-monospace, monospace; opacity: 0.6; }
    .kn-svg .vec { stroke: currentColor; stroke-width: 1.4; opacity: 0.8; }
  </style>

  <text class="h2" x="24" y="24">true second-order cone (Kinetic)</text>
  <line class="axis2" x1="30" y1="130" x2="230" y2="130"/>
  <line class="axis2" x1="130" y1="46" x2="130" y2="214"/>
  <circle class="cone" cx="130" cy="130" r="62"/>
  <line class="vec" x1="130" y1="130" x2="174" y2="86"/>
  <line class="vec" x1="130" y1="130" x2="192" y2="130"/>
  <text class="m2" x="24" y="212">|λ_t| ≤ μ λ_n in every direction</text>

  <text class="h2" x="330" y="24">four-sided pyramid (common)</text>
  <line class="axis2" x1="336" y1="130" x2="536" y2="130"/>
  <line class="axis2" x1="436" y1="46" x2="436" y2="214"/>
  <polygon class="pyr" points="436,68 498,130 436,192 374,130"/>
  <line class="vec" x1="436" y1="130" x2="480" y2="86"/>
  <line class="vec" x1="436" y1="130" x2="498" y2="130"/>
  <text class="m2" x="330" y="212">grip is 41% weaker along the axes</text>
</svg>
  <p class="kn-caption">Both vectors have the same magnitude. Under a pyramid the
  diagonal one is still inside the limit while the axial one is at it, so a
  sliding box curves toward the diagonal. The cone projection is one square root
  and a scale, and the artefact disappears.</p>
</div>


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
