# Glossary

Terms as Kinetic uses them. Where a word means something narrower here than in
general usage, the narrower meaning is the one that applies.

**Articulation** — a kinematic tree of links. A free-floating rigid body is an
articulation with one link and a free joint, so the solver only ever handles one
kind of object.

**Armature** — rotor inertia reflected through a gearbox, added to the diagonal
of the mass matrix. Physically real for geared actuators, and the single most
effective knob for making a high-gain position controller stable.

**Baumgarte stabilisation** — correcting constraint *position* error by injecting
a velocity bias. Kinetic uses a soft variant parameterised by a time constant and
damping ratio rather than a raw gain; see [the solver](../physics/solver.md).

**Broadphase** — the cheap pass that finds which geom pairs *might* touch.
Kinetic sorts axis-aligned bounding boxes along X (sweep and prune).

**CFM (constraint force mixing)** — a term added to the diagonal of the
constraint system that lets it be violated slightly in exchange for
conditioning. Kinetic derives it from the material's time constant.

**Contact margin** — the distance within which contacts are generated. Because
contacts are speculative, a margin does not make objects hover.

**CRBA (composite rigid body algorithm)** — the O(n²) recursion that builds the
joint-space inertia matrix **M**.

**Degrees of freedom (nv)** — the size of the velocity vector. Differs from **nq**
because rotations are stored as quaternions but their velocities are 3-vectors.

**Delassus operator** — `A = J M⁻¹ Jᵀ`, the effective inverse inertia the
constraint set sees. Kinetic forms it per block, never globally.

**EPA (expanding polytope algorithm)** — recovers penetration depth and normal
after GJK has found that two shapes overlap.

**Equality constraint** — a connection the tree cannot express: a weld, a ball
joint between two articulations, or a locked coordinate. Solved with contacts.

**Featherstone** — Roy Featherstone, whose spatial-vector formulation of
articulated dynamics Kinetic follows, with one deviation: everything is expressed
in the world frame.

**Friction cone** — the set of admissible friction impulses,
`√(λ₁² + λ₂²) ≤ μ λₙ`. Kinetic projects onto the true cone rather than a
linearised pyramid, so grip does not depend on sliding direction.

**Geom** — one collision or visual shape attached to a link. A link may carry
many; `collidable` and `visible` are independent.

**GJK (Gilbert-Johnson-Keerthi)** — finds the distance between two convex shapes
through a support mapping.

**Island** — a connected component of the constraint graph. Kinetic does not
split into islands; the solver sweeps all blocks in order.

**Jacobian** — the matrix mapping generalised velocity to the velocity of
something you care about. A contact's Jacobian maps `qvel` to the relative
velocity at the contact point.

**LDLᵀ** — the symmetric factorisation of the mass matrix, used to apply `M⁻¹`
without ever forming an inverse.

**Link** — one rigid body in an articulation. Its frame sits at its joint.

**Manifold** — the set of contact points between one pair of geoms, up to four.
A single point cannot stop a box from rocking.

**Motion subspace (S)** — the columns describing how a joint's velocity maps into
its child's spatial velocity. For a revolute joint at world point `p` about axis
`a`, `S = [a; p × a]`.

**Narrowphase** — the exact per-pair contact computation that follows the
broadphase.

**PGS (projected Gauss-Seidel)** — the iterative solver. Each row is solved and
its impulse applied immediately, which is why it converges in tens of iterations
rather than hundreds — and why it is inherently sequential.

**Quickhull** — the algorithm that reduces an imported mesh to its convex hull,
so the support mapping scans hundreds of vertices rather than tens of thousands.

**Reduced coordinates** — representing state as joint values rather than as the
pose of every body. Joints then cannot drift apart, because there is no
representation in which they are separated.

**Restitution** — the fraction of approach velocity returned on impact. Engages
only above a threshold speed so resting bodies do not buzz.

**RNEA (recursive Newton-Euler algorithm)** — the O(n) recursion that computes
the Coriolis, centrifugal and gravitational bias forces.

**Slop (penetration slop)** — the overlap tolerated before position correction
pushes back. Prevents the solver from fighting over the last micron.

**Spatial vector** — a 6D vector pairing angular and linear parts. Motion vectors
are `[ω; v_O]`, force vectors `[n_O; f]`.

**Speculative contact** — a contact created *before* the surfaces touch, whose
constraint allows approach only up to the remaining gap. Removes both tunnelling
and steady-state penetration.

**Sweep and prune** — the broadphase: sort interval endpoints along an axis and
walk them keeping an active set.

**Swept AABB** — a bounding box extended along the body's motion for this step,
so a fast body's whole path is covered by the broadphase.

**Torsional friction** — resistance to spin about the contact normal. Point
friction cannot supply it, so a sphere or a flat foot would otherwise pivot
freely.

**Warm starting** — beginning each solver sweep from the previous step's
impulses. Worth roughly an order of magnitude in iteration count for a resting
stack.
