# Rigid-body dynamics

Kinetic is a **reduced-coordinate** engine. A robot's state is its joint angles,
not the pose of every link, so a joint cannot drift apart no matter how stiff the
mechanism or how large the timestep. Constraints that *can* be violated —
contacts, joint limits, loop closures — go to the solver; the tree structure is
exact by construction.

## Spatial algebra in the world frame

The dynamics use 6D spatial (Plücker) vectors in Featherstone's formulation, with
one deliberate deviation: **everything is expressed in the world frame**, not in
each link's own frame.

A motion vector is ordered \\([\\omega; v_O]\\), where the linear part is the
velocity of the body-fixed point instantaneously coincident with the world
origin:

\\[ v_O = v_P - \\omega \\times p_P \\]

A force vector is \\([n_O; f]\\) — torque about the origin, then force.

The usual formulation transforms between per-link frames at every step. Working
in a single global frame costs a little arithmetic and buys a lot: contact
Jacobians assemble without a single frame conversion, the renderer reads link
poses directly, and there is no class of bug where a quantity is right but
expressed in the wrong frame.

With that convention, a revolute joint at world point \\(p\\) about world axis
\\(a\\) has motion subspace

\\[ S = \\begin{bmatrix} a \\\\ p \\times a \\end{bmatrix} \\]

and a prismatic joint along \\(a\\) has \\(S = [0;\\, a]\\). A free joint
contributes three translational columns \\([0;\\, e_i]\\) and three rotational
columns \\([e_i;\\, p \\times e_i]\\).

<div class="kn-figure">
<svg viewBox="0 0 700 250" role="img" aria-label="World-frame spatial vector convention" class="kn-svg">
  <style>
    .kn-svg .ax { stroke: currentColor; stroke-width: 1.2; opacity: 0.45; }
    .kn-svg .lk { fill: none; stroke: currentColor; stroke-width: 1.6; opacity: 0.7; }
    .kn-svg .dot { fill: currentColor; }
    .kn-svg .acc { stroke: #0070f3; stroke-width: 1.8; fill: none; }
    .kn-svg .accdot { fill: #0070f3; }
    .kn-svg .lbl { fill: currentColor; font: 600 12px ui-sans-serif, system-ui, sans-serif; }
    .kn-svg .mono { fill: currentColor; font: 400 11px ui-monospace, monospace; opacity: 0.62; }
    .kn-svg .acclbl { fill: #0070f3; font: 600 12px ui-monospace, monospace; }
    .kn-svg .ghost { stroke: currentColor; stroke-width: 1; opacity: 0.25;
                     stroke-dasharray: 4 4; fill: none; }
  </style>

  <line class="ax" x1="70" y1="200" x2="330" y2="200"/>
  <line class="ax" x1="70" y1="200" x2="70" y2="50"/>
  <circle class="dot" cx="70" cy="200" r="3.5"/>
  <text class="lbl" x="52" y="220">O</text>
  <text class="mono" x="46" y="234">world origin</text>

  <line class="lk" x1="210" y1="150" x2="300" y2="90"/>
  <circle class="dot" cx="210" cy="150" r="4.5"/>
  <text class="lbl" x="196" y="140">p</text>
  <text class="mono" x="150" y="172">joint anchor</text>
  <circle class="accdot" cx="300" cy="90" r="4"/>
  <text class="mono" x="308" y="88">link</text>

  <path class="ghost" d="M70 200 L210 150"/>
  <text class="mono" x="112" y="188">p (position of the anchor)</text>

  <path class="acc" d="M210 150 m-26,-16 a30 30 0 1 1 6 30" marker-end="url(#kn-arrow)"/>
  <text class="acclbl" x="150" y="118">ω = a q̇</text>

  <defs>
    <marker id="kn-arrow" viewBox="0 0 10 10" refX="8" refY="5"
            markerWidth="5" markerHeight="5" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#0070f3"/>
    </marker>
  </defs>

  <line x1="380" y1="40" x2="380" y2="215" class="ax"/>

  <text class="lbl" x="410" y="60">Motion vector, world frame</text>
  <text class="mono" x="410" y="82">v = [ ω ; v_O ]</text>
  <text class="mono" x="410" y="100">v_O = v_P − ω × p_P</text>

  <text class="lbl" x="410" y="132">Revolute joint at p, axis a</text>
  <text class="mono" x="410" y="154">S = [ a ; p × a ]</text>

  <text class="lbl" x="410" y="186">Point velocity, no transform</text>
  <text class="mono" x="410" y="208">v_P = v_O + ω × p_P</text>
</svg>
  <p class="kn-caption">The linear part of a motion vector is the velocity of the
  body-fixed point instantaneously at the world origin. Because every quantity
  already lives in the world frame, assembling a contact Jacobian is one cross
  product per degree of freedom — no frame conversions anywhere in the loop.</p>
</div>


## Spatial inertia

A body of mass \\(m\\) whose centre of mass is at world point \\(c\\), with
rotational inertia \\(I_c\\) about that centre rotated into world axes, has
spatial inertia about the origin

\\[
I_6 = \\begin{bmatrix}
I_c - m\\,[c]_\\times [c]_\\times & m\\,[c]_\\times \\\\
-m\\,[c]_\\times & m\\,\\mathbb{1}
\\end{bmatrix}
\\]

which is symmetric because \\([c]_\\times^{\\mathsf T} = -[c]_\\times\\). Kinetic
stores it as \\((m,\; h = mc,\; I)\\) and never forms the 6×6 explicitly.

## Forward kinematics

One forward pass over links, parents before children (`compile()` guarantees that
ordering). For each link it computes the world pose, the joint anchor, the world
centre of mass, the spatial inertia, the motion subspace columns, and the spatial
velocity

\\[ v_i = v_{\\lambda(i)} + \\sum_k S_k \\dot q_k \\]

where \\(\\lambda(i)\\) is the parent.

## The joint-space inertia matrix (CRBA)

The composite-rigid-body algorithm builds \\(M\\) in one reverse pass and one
sparse fill. Composite inertias accumulate up the tree,

\\[ I^C_{\\lambda(i)} \\mathrel{+}= I^C_i \\]

and each entry is a dot product between a spatial force and a motion subspace:

\\[ M_{ab} = S_a^{\\mathsf T} \\left( I^C_i S_b \\right) \\]

filled only for \\(b\\) on the path from \\(i\\) to the root, then mirrored.
Because the subspaces are already in world coordinates there are no transforms
inside the loop.

Rotor inertia (`armature`) is added to the diagonal. It is physically real for
geared actuators and it makes \\(M\\) better conditioned.

`world.massMatrix(articulation:)` returns this matrix. It is symmetric positive
definite, and the test suite asserts both properties plus
\\(T = \\tfrac12 v^{\\mathsf T} M v\\).

## Bias forces (RNEA)

The recursive Newton-Euler algorithm evaluated with \\(\\ddot q = 0\\) gives the
Coriolis, centrifugal and gravitational terms in one forward and one reverse
pass:

\\[
a_i = a_{\\lambda(i)} + v_i \\times S_i \\dot q_i, \\qquad
f_i = I_i a_i + v_i \\times^{*} (I_i v_i)
\\]

\\[ c_k = S_k^{\\mathsf T} f_i, \\qquad f_{\\lambda(i)} \\mathrel{+}= f_i \\]

Gravity enters through the root's acceleration, \\(a_0 = [0;\\, -g]\\) — the
standard trick that makes weight fall out of the same recursion instead of
needing a separate pass.

## Solving for acceleration

The equation of motion is

\\[ M\\ddot q + c(q, \\dot q) = \\tau \\]

`factorMass` takes the LDLᵀ of \\(M\\), and `unconstrainedAcceleration` solves

\\[ \\ddot q_{\\text{free}} = M^{-1}(\\tau - c) \\]

\\(O(n^3)\\) is the right choice here. For a 30-dof robot a dense factorisation
is a few microseconds and the cache behaviour beats a sparse articulated-body
recursion; the sparse advantage only appears at hundreds of degrees of freedom.

### Implicit damping

Viscous terms — joint damping and the derivative gain of position and velocity
actuators — are folded into the left-hand side before factorising:

\\[ (M + h D)\\,\\ddot q = \\tau - c - D\\dot q \\]

This costs nothing (the diagonal is already being touched) and removes the usual
stability ceiling on how large \\(k_d\\) can be for a given timestep. A position
actuator with `kp: 800, kd: 60` is stable at 500 Hz, where an explicit
integrator would need several kilohertz.

## Point Jacobians

For a world point \\(p\\) rigidly attached to link \\(L\\), the column for dof
\\(k\\) is

\\[ J_k = S_{k,\\text{lin}} + S_{k,\\text{ang}} \\times p \\]

for every \\(k\\) on the path from \\(L\\) to the root, and zero elsewhere. This
is what the contact solver assembles and what `pointJacobian` returns. The test
suite checks it against a central finite difference of forward kinematics.

## Diagnostics

```swift
world.kineticEnergy      // ½ vᵀ M v, including the armature term
world.potentialEnergy    // −Σ mᵢ g · cᵢ
world.centerOfMass
world.linearMomentum
world.angularMomentum    // about the system centre of mass
```

Angular momentum is reported about the centre of mass rather than the world
origin, because \\(L_O = L_c + r \\times p\\) drifts for any translating system
and would be useless as a conservation check.
