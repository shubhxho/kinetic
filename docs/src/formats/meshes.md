# Meshes

Kinetic reads **STL** (binary and ASCII), **OBJ**, and **ASCII PLY**.

```swift
let library = MeshLibrary(searchPaths: [packageRoot])
let mesh = try library.load("package://my_robot/meshes/link.stl",
                            scale: Vec3(0.001, 0.001, 0.001))
```

## Resolution

Mesh URIs are resolved in this order:

1. `file://` URLs directly
2. the path as given, if it exists
3. each search path + the full relative path
4. each search path + the path with its leading package component removed

Both `package://my_robot/meshes/link.stl` and `meshes/link.stl` therefore resolve
against a search path that contains `meshes/`, which covers the two layouts real
ROS packages ship in.

`URDF.load(contentsOf:)` automatically adds the file's own directory and its
parent. Add more through `URDFImportOptions.packageRoots`; MJCF also honours
`<compiler meshdir>`.

## Hull versus triangles

Loading a mesh produces both representations:

| Use | Geometry | Why |
| --- | --- | --- |
| collision | convex hull | the support mapping is a linear scan over vertices |
| visual | original triangles | fidelity, and visual geoms are never queried |

A 20,000-triangle arm link typically hulls to a few hundred vertices describing
exactly the same convex volume. Without that step every GJK iteration would scan
the full soup and the narrowphase would dominate the step.

```swift
mesh.vertices        // authored triangles
mesh.indices
mesh.hullVertices    // convex hull
mesh.hullIndices
mesh.volume          // of the hull, by signed-tetrahedron sum
mesh.centroid
mesh.boundingRadius
mesh.usedFallbackHull
```

## Quickhull

`ConvexHull.compute(points:)` implements Quickhull in three dimensions: build a
well-conditioned initial tetrahedron from axis extremes, then repeatedly absorb
the point furthest outside a face, deleting every face that point can see and
re-triangulating the resulting horizon.

Two details matter for robustness:

- **Faces are oriented against a known interior point**, not by winding order
  alone. Without this, cone faces built during expansion can end up
  inward-facing, and the hull silently loses geometry.
- **Degenerate input falls back to the oriented bounding box.** Fewer than four
  points, or points that are collinear or coplanar within tolerance, produce a
  box with a little thickness so mass properties and the support mapping stay
  well defined. `usedFallbackHull` reports when this happened.

Input points are deduplicated at 0.1 µm, below any meaningful robot tolerance.

Hulls are capped at 256 vertices by default. Above that the least-extremal
vertices are dropped and the hull is rebuilt.

## Concave geometry

Kinetic collides convex shapes only. A concave mesh becomes its convex hull —
a bowl will not hold anything and a C-clamp will not close around a bar.

If the concavity matters, decompose upstream into convex parts (V-HACD or
similar) and attach one geom per part to the same link. That is what the
`localPose` on `GeomSpec` is for, and it is also what most MJCF models already
do.

## Scale

Applied before hulling, so mass properties and the hull are both computed in
final units.

```xml
<mesh filename="package://robot/meshes/link.stl" scale="0.001 0.001 0.001"/>
```

Millimetre-authored CAD is the usual reason to need it.

## Rejected formats

COLLADA (`.dae`), glTF (`.gltf`, `.glb`) and binary PLY raise an error rather
than being approximated. They carry scene graphs, transforms and materials this
importer does not model, and silently loading only their first mesh would produce
a wrong robot rather than an obvious failure. Convert to STL or OBJ.

## Deriving mass from a mesh

```swift
let mass = mesh.volume * density
world.setInertial(articulation: art, link: link, mass: mass,
                  com: mesh.centroid,
                  inertia: Inertia.box(mass: mass,
                                       halfExtents: (mesh.aabbMax - mesh.aabbMin) * 0.5))
```

The volume and centroid are exact for the hull. The inertia tensor here is a
bounding-box approximation; if you need the exact tensor of the hull, compute it
from the signed-tetrahedron decomposition of `hullIndices`.
