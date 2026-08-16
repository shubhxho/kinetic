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
