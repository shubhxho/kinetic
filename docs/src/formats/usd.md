# USD

USD is what Omniverse and Isaac Sim actually ship, so Kinetic reads it — with a
boundary that is stated rather than blurred.

```swift
let document = try USDImporter.inspect(contentsOf: url)
let nodes = try USDImporter.loadGeometry(contentsOf: url, options: options)
let robot = try USDImporter.addToWorld(url, world: world, options: options)
```

## What you get, and what you do not

macOS ships ModelIO, and `MDLAsset` reads `.usd`, `.usda`, `.usdc` and `.usdz`.
It runs a real USD composition engine, so references, payloads and variants are
resolved for geometry. What it does **not** expose is the `UsdPhysics` schema:
joints, masses, articulation roots and collision approximations are simply not
surfaced by that API. Physics prims such as `PhysicsRevoluteJoint` arrive as bare
objects carrying a name and a path and nothing else.

So the split is honest and hard:

| | Source | Coverage |
| --- | --- | --- |
| Prim hierarchy, transforms, triangles, materials | ModelIO | complete, any encoding |
| `metersPerUnit`, `upAxis` | ModelIO / text | complete for ASCII; up-axis only for binary |
| Rigid bodies, masses, joints, drives | Kinetic's own `.usda` text parser | ASCII layers only |
| Everything else | — | reported, never invented |

Collision hulls come from the same `ConvexHull.compute` that `MeshLoader` uses,
so a USD mesh collides identically to an imported STL.

## Up axis and units

USD is frequently Y-up and frequently authored in centimetres. Kinetic is Z-up
and metric, so the importer applies a **+90° rotation about +X**:

\\[ (x,\\, y,\\, z) \\rightarrow (x,\\, -z,\\, y) \\]

determinant +1, so no winding flip is needed. It is applied pointwise to mesh
vertices and by **conjugation** to node transforms, \\(M' = R M R^{-1}\\) — which
is what keeps the two consistent, since with \\(p' = Rp\\) you need
\\(M'p' = R(Mp)\\). The same treatment is applied to `physics:localPos0/1`,
`physics:localRot0/1` and `physics:axis`.

ModelIO applies neither the unit scale nor the up-axis rotation itself: a cube
authored at `metersPerUnit = 0.01` comes back at ±50. Both conversions are
Kinetic's, and both are verified numerically in the test suite.

## Physics recovered from ASCII layers

`USDPhysics.parse` recognises `PhysicsRigidBodyAPI`, `PhysicsMassAPI`
(`physics:mass`, `physics:density`, `physics:centerOfMass`,
`physics:diagonalInertia`, `physics:principalAxes`), `PhysicsCollisionAPI`,
`PhysicsArticulationRootAPI`, `PhysicsDriveAPI`, and the four joint types with
their axis, local frames and limits.

`USDPhysicsScene` reports a `coverage` fraction and an `unsupported` list, so you
can see how much of the file was understood rather than guessing.

`buildArticulation` assembles a real kinematic tree when the joint graph is a
tree, and throws `kinematicLoop` naming `World.connect` / `World.weld` when it is
not — loops need equality constraints, which the tree cannot express.

## Nothing is invented silently

- No `physics:mass` and no `physics:density` → mass is hull volume × the
  configured density, **with a per-body warning naming the number used**.
- No `physics:diagonalInertia` → the tensor is integrated exactly over the body's
  hulls by signed-tetrahedron decomposition, with a warning.
- A body with no geometry → a 1 g placeholder, announced.
- Shear or mirroring in a transform → reported.
- `requirePhysics = true` turns every one of those downgrades into an error.

## Binary layers

`.usdc` and `.usdz` are crate- and zip-encoded. Kinetic refuses to parse them as
text rather than guessing:

```text
panda.usdc is crate-encoded and cannot be parsed as text. Convert it with
`usdcat -o flat.usda panda.usdc` and parse that.
```

Geometry still imports fully from binary layers — only the physics half needs the
conversion.

## A layer parser, not a composition engine

The text parser reads the layer you hand it. If a robot's physics lives in a
referenced layer, geometry will be complete and physics empty; every such
reference is listed in `unsupported` and drags `coverage` down, so the situation
is visible rather than mysterious.
