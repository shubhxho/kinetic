# Accuracy and validation

Every claim on this page is produced by `kinetic validate`, which exits non-zero
on failure and is meant to be run in CI.

```bash
kinetic validate
```

```text
Physics validation

  PASS  free fall                         error 0.00 nm
  PASS  resting contact                   penetration 0.000 mm
  PASS  pendulum energy drift             0.210 % over 10 s
  PASS  angular momentum (RK4)            drift 0.0008 %
  PASS  Coulomb friction                  held 0.00 mm, slid 1.623 m
  PASS  box stack stability               max drift 7.31 mm
  PASS  no tunnelling at 120 m/s          stopped at x = -0.1114 m
  PASS  threaded narrowphase determinism  420 coordinates compared
  PASS  determinism                       168 coordinates compared

  all checks passed
```

## What each check proves

### Free fall — exact to the last bit

A sphere falls for 500 steps with contacts disabled. Semi-implicit Euler has a
closed form:

\\[ z_n = z_0 - g h^2 \\frac{n(n+1)}{2} \\]

The measured error is below 1 nanometre — that is, the integrator is producing
the exact discrete solution, and gravity, the mass matrix and the free-joint
integration are all consistent. Any sign error or frame confusion anywhere in the
pipeline breaks this immediately.

### Resting contact — no steady-state penetration

A 0.2 m sphere is dropped from 1 m and settles. It rests at exactly 0.2 m.

Before speculative contacts this test settled 0.5 mm into the floor — the
classic soft-constraint equilibrium where restoring force balances weight. The
speculative formulation removes it: a separated point may approach by at most its
remaining gap, so the body lands on the surface rather than through it.

### Pendulum energy — 0.21% over 10 s

An undamped rigid pendulum released from 1.5 rad, integrated for 20,000 steps at
2 kHz. Total energy drifts 0.21%.

For a first-order integrator this is the expected order of magnitude, and the
drift is bounded rather than secular — the value oscillates around the initial
energy instead of climbing. That is the signature of a symplectic-like scheme and
confirms the Coriolis terms in RNEA are right.

### Angular momentum — 8 × 10⁻⁶ under RK4

A box with three distinct principal moments tumbles for 8 s in zero gravity. With
RK4, angular momentum about the centre of mass is conserved to 0.0008%.

This is the check that exercises the gyroscopic term \\(\\omega \\times I\\omega\\).
Under semi-implicit Euler the same test drifts 2.42%, which is why RK4 exists.

Momentum is measured about the **centre of mass**, not the origin, since
\\(L_O = L_c + r \\times p\\) drifts for any translating body.

### Coulomb friction — holds, then slips

A 4 kg box on μ = 1.0 ground. Its weight is 39.2 N, so the friction cone bounds
tangential force at 39.2 N.

- Pushed at 20 N for 300 steps: moves less than 3 mm.
- Pushed at 120 N for 300 steps: slides 1.62 m.

Static friction genuinely holds — no creep — and the transition happens where
the cone says it should.

### Box stack — ten boxes stay stacked

Ten 0.2 m boxes, dropped and simulated for 6 s. Every box ends within 20 mm of
its ideal height, with a maximum drift of 7 mm.

This is the integration test for the whole contact path: box–box SAT with face
clipping, four-point manifolds, warm starting, and the solver's ability to
propagate a load through a chain of contacts.

### No tunnelling at 120 m/s

A 40 mm sphere is fired at 120 m/s at a 10 mm wall. At 500 Hz it travels 240 mm
per step — 24× the wall thickness.

It stops. Swept AABBs find the pair before the crossing, and the speculative
contact bounds the approach to the remaining gap.

### Determinism, twice

Two identical runs of a 25-body mixed-primitive scene produce bit-identical
coordinates. A 60-domino scene produces bit-identical results with the threaded
narrowphase on and off.

The second check is the one that matters: it proves the parallel path is not
merely close but exactly equal, which is what makes a bug reproducible from a
recording.

## The unit test suite

`swift test` runs 44 tests across nine suites. Beyond the checks above:

| Suite | Notable assertions |
| --- | --- |
| Rigid-body dynamics | contact force balances weight to 5%; restitution bounce height; joint limits under load; position actuator convergence; state save/restore round-trip |
| Kinematics | point Jacobian against a central finite difference of forward kinematics; mass matrix symmetric and Cholesky-factorable; \\(T = \\tfrac12 v^{\\mathsf T} M v\\); raycast distance and normal |
| Constraints | connect constraint holds a hanging body; self-collision toggles correctly |
| Convex hull | cube cloud collapses to 8 corners with exact volume; every input point inside every face plane; inscribed sphere volume; degenerate fallback; vertex cap |
| Mesh import | binary STL geometry and mass properties; scaling applied before hulling; OBJ polygons and negative indices; `package://` resolution; a hulled mesh rests on the ground |
| URDF / MJCF | topology, limits, inertial rotation, `fromto` capsules, options, actuators |
| Recording | frame-exact round-trip, seeking, channel extraction, CSV export |
| Transport | WebSocket framing across every length class, partial frames, client masking |

## Known limits

Stated plainly, because a validation page that only lists passes is marketing.

- **Semi-implicit Euler drifts on gyroscopic terms.** 2.4% over 8 s for an
  asymmetric tumbling body. Use RK4 when that matters.
- **RK4 degrades to Euler under contact.** By design; see
  [Integration](./integration.md).
- **Contacts are soft.** A sufficiently large mass ratio (>10⁴) will show visible
  compliance. This is true of every impulse-based solver.
- **Only convex collision.** Concave meshes are approximated by their convex
  hull. Decompose them upstream if the concavity matters.
- **No fluids, cloth, soft bodies or deformables.**
- **Heightfields are declared but not implemented.** `GeomType::Heightfield`
  exists in the ABI and is not yet backed by a narrowphase routine.
- **COLLADA, glTF and binary PLY meshes are rejected** rather than approximated.
  Convert to STL or OBJ.
