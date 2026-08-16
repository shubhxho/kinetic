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
