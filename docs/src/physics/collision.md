# Collision detection

Collision runs in three stages: bound the geometry, find candidate pairs, then
compute contacts for the pairs that survive.

## Bounding and sweeping

Each geom's world AABB is grown by the contact margin, then **extended along its
motion for this step**:

```cpp
Vec3 motion = link.velocity.pointVelocity(pose.pos) * h;
for (int axis = 0; axis < 3; ++axis) {
    Scalar d = clamp(motion[axis], -2.0, 2.0);
    if (d < 0) aabb.min[axis] += d; else aabb.max[axis] += d;
}
```

Directional, not isotropic. Growing by `|motion|` in all six directions inflates
the volume by up to 8× and floods the broadphase with pairs that were never going
to touch.

Because the swept bound contains the body's whole path, a pair that *will* collide
during the step is always found — which is what makes the speculative contacts in
the solver able to stop it.

<div class="kn-figure">
<svg viewBox="0 0 700 200" role="img" aria-label="Directional versus isotropic AABB sweeping" class="kn-svg">
  <style>
    .kn-svg .obj { fill: none; stroke: currentColor; stroke-width: 1.5; opacity: 0.8; }
    .kn-svg .tight { fill: none; stroke: currentColor; stroke-width: 1; opacity: 0.4;
                     stroke-dasharray: 3 3; }
    .kn-svg .wrongbox { fill: #f5a623; fill-opacity: 0.10; stroke: #f5a623;
                        stroke-width: 1.3; stroke-dasharray: 4 3; }
    .kn-svg .rightbox { fill: #0cce6b; fill-opacity: 0.10; stroke: #0cce6b;
                        stroke-width: 1.3; stroke-dasharray: 4 3; }
    .kn-svg .mv { stroke: #0070f3; stroke-width: 1.8; }
    .kn-svg .h3 { fill: currentColor; font: 600 12px ui-sans-serif, system-ui, sans-serif; }
    .kn-svg .m3 { fill: currentColor; font: 400 10.5px ui-monospace, monospace; opacity: 0.6; }
    .kn-svg .warn { fill: #f5a623; font: 600 10.5px ui-monospace, monospace; }
    .kn-svg .ok { fill: #0cce6b; font: 600 10.5px ui-monospace, monospace; }
  </style>

  <defs>
    <marker id="kn-mv" viewBox="0 0 10 10" refX="9" refY="5"
            markerWidth="5" markerHeight="5" orient="auto-start-reverse">
      <path d="M 0 0 L 10 5 L 0 10 z" fill="#0070f3"/>
    </marker>
  </defs>

  <text class="h3" x="24" y="24">grown by |motion| in all six directions</text>
  <rect class="wrongbox" x="40" y="46" width="180" height="110" rx="3"/>
  <rect class="tight" x="110" y="86" width="40" height="30"/>
  <circle class="obj" cx="130" cy="101" r="14"/>
  <line class="mv" x1="130" y1="101" x2="196" y2="101" marker-end="url(#kn-mv)"/>
  <text class="warn" x="24" y="180">8× the volume, floods the broadphase</text>

  <text class="h3" x="380" y="24">extended along the motion only</text>
  <rect class="rightbox" x="396" y="86" width="176" height="30" rx="3"/>
  <rect class="tight" x="396" y="86" width="40" height="30"/>
  <circle class="obj" cx="416" cy="101" r="14"/>
  <line class="mv" x1="416" y1="101" x2="482" y2="101" marker-end="url(#kn-mv)"/>
  <text class="ok" x="380" y="180">contains the whole path, nothing more</text>
</svg>
  <p class="kn-caption">The swept bound must contain the body's entire path for
  the step, or a speculative contact never gets the chance to stop it. It does
  not have to contain anything else.</p>
</div>


## Broadphase

Sweep-and-prune along the X axis: sort 2N endpoints, walk them keeping an active
set, and emit overlapping pairs.

The sort is made total by breaking value ties on `isMin` first and then on index,
so pair ordering is deterministic regardless of how the standard library's sort
happens to behave.

An incremental structure (BVH, hash grid) would beat this asymptotically, but at
the hundreds-to-few-thousand geoms Kinetic targets, the bookkeeping costs more
than the sort saves.

## Filtering

Before narrowphase, a pair is dropped if any of these hold:

- either geom has `collidable = false`
- the group/mask bitmasks do not overlap in both directions
- both geoms are on the same link
- both are in the same articulation and self-collision is off
- both are in the same articulation and the links are parent and child (they
  share a joint and always interpenetrate slightly)
- both articulations have zero degrees of freedom (static against static)
- either articulation is disabled

## Narrowphase

Pairs with a closed form get one. They produce a full manifold in a single call,
which is far more stable for stacking than accumulating points over frames.

| Pair | Method | Points |
| --- | --- | --- |
| sphere–sphere | analytic | 1 |
| sphere–box | closest point on box, with an interior fallback | 1 |
| sphere–capsule | point–segment | 1 |
| capsule–capsule | segment–segment, plus a 2-point manifold when near-parallel | 1–2 |
| box–box | SAT over 15 axes, then reference-face clipping | 1–4 |
| plane–anything | vertex/rim sampling against the half-space | 1–4 |
| everything else | GJK for separation, EPA for penetration | 1 (accumulated) |

### GJK and EPA

The generic path builds the Minkowski difference through a support mapping and
runs GJK to find either the closest features or a tetrahedron enclosing the
origin. If it encloses the origin, EPA expands that polytope face by face until
the supporting plane stops moving, and returns the penetration normal, depth, and
witness points recovered from barycentric coordinates on the closest face.

For a convex hull, the support mapping is a linear scan over the hull's vertices.
This is why imported meshes are hulled at load time — scanning a 20,000-vertex
triangle soup per query would dominate the step.

### Persistent manifolds

A single-point result is not enough to stop a box from rocking, so GJK pairs
accumulate contacts across steps. Each point stores its anchor in both geoms'
local frames. On the next step the anchors are re-projected through the current
poses and a point is dropped if it has separated past the margin or drifted more
than 10 mm tangentially. New points merge into existing ones within 5 mm,
inheriting their warm-start impulses.

A manifold holds at most four points. When a fifth arrives, the point whose
removal costs least — scored on depth and spread — is evicted.

<div class="kn-figure">
<svg viewBox="0 0 700 210" role="img" aria-label="Persistent contact manifold across steps" class="kn-svg">
  <style>
    .kn-svg .shape { fill: none; stroke: currentColor; stroke-width: 1.5; opacity: 0.75; }
    .kn-svg .surf { stroke: currentColor; stroke-width: 1.4; opacity: 0.5; }
    .kn-svg .pt { fill: #0070f3; }
    .kn-svg .old { fill: none; stroke: #0070f3; stroke-width: 1.2; opacity: 0.65; }
    .kn-svg .drop { fill: none; stroke: #ff4d4f; stroke-width: 1.2; }
    .kn-svg .h4 { fill: currentColor; font: 600 12px ui-sans-serif, system-ui, sans-serif; }
    .kn-svg .m4 { fill: currentColor; font: 400 10px ui-monospace, monospace; opacity: 0.6; }
    .kn-svg .step { fill: currentColor; font: 600 10px ui-monospace, monospace; opacity: 0.4; }
  </style>

  <text class="step" x="30" y="24">step n</text>
  <polygon class="shape" points="40,60 130,50 140,120 50,130"/>
  <line class="surf" x1="20" y1="140" x2="160" y2="140"/>
  <circle class="pt" cx="52" cy="131" r="4"/>
  <text class="m4" x="20" y="176">GJK returns one point</text>

  <text class="step" x="250" y="24">step n+1</text>
  <polygon class="shape" points="256,58 346,50 356,120 266,132"/>
  <line class="surf" x1="236" y1="140" x2="376" y2="140"/>
  <circle class="old" cx="268" cy="133" r="4"/>
  <circle class="pt" cx="348" cy="126" r="4"/>
  <text class="m4" x="236" y="176">old anchor re-projected,</text>
  <text class="m4" x="236" y="190">new point added</text>

  <text class="step" x="470" y="24">step n+2</text>
  <polygon class="shape" points="476,62 566,56 570,124 480,132"/>
  <line class="surf" x1="456" y1="140" x2="596" y2="140"/>
  <circle class="old" cx="482" cy="133" r="4"/>
  <circle class="old" cx="524" cy="131" r="4"/>
  <circle class="pt" cx="568" cy="128" r="4"/>
  <text class="m4" x="456" y="176">manifold reaches four points;</text>
  <text class="m4" x="456" y="190">impulses warm-start each step</text>
</svg>
  <p class="kn-caption">A single point cannot stop a box rocking. Points carry
  anchors in both geoms' local frames, are re-projected through the current
  poses, and are dropped once they separate past the margin or drift more than
  10 mm tangentially.</p>
</div>


## Warm starting

Analytic pairs rebuild their manifold every step, so they inherit impulses by
matching each new point to the nearest previous one within 20 mm of local-frame
distance. Persistent pairs carry impulses on the points themselves.

Either way the solver starts each step from the previous solution, which is worth
roughly an order of magnitude in iteration count for a resting stack.

## Raycasting

`world.raycast` has closed forms for every primitive, and Möller-Trumbore against
mesh triangles. It respects group masks and can ignore an articulation, which is
what a rangefinder sensor mounted on a robot needs so it does not see its own
body.

```swift
if let hit = world.raycast(origin: eye, direction: forward, maxDistance: 10) {
    print(hit.distance, hit.point, hit.normal, hit.link)
}
```
