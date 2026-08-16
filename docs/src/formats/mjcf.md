# MJCF

MuJoCo's XML dialect. Kinetic reads the modelling subset that describes rigid-body
physics.

```swift
let (world, robot) = try MJCF.load(contentsOf: url)
```

## Supported

| Element | Notes |
| --- | --- |
| `<option timestep gravity iterations>` | applied to `world.options` |
| `<default>` and `<default class>` | geom, joint and actuator defaults |
| `<asset><mesh name file scale>` | loaded, hulled and registered |
| `<compiler meshdir>` | added to the mesh search path |
| `<worldbody>` | static geoms become a fixed root link |
| `<body pos quat euler axisangle zaxis>` | nested tree |
| `<joint type="hinge\|slide\|ball">` | revolute, prismatic, spherical |
| `<freejoint>`, `<joint type="free">` | floating base |
| `<geom type size fromto pos quat rgba friction density mass solref contype conaffinity>` | full geom |
| `<inertial mass pos diaginertia fullinertia>` | explicit inertial |
| `<actuator><motor\|position\|velocity\|damper>` | actuators bound by joint name |

## The frame difference

MuJoCo puts the body frame at `body/@pos` and expresses the joint anchor *inside*
that frame. Kinetic puts the link frame **at the joint anchor**.

The importer reconciles this by shifting every geom, inertial and child body by
the anchor offset. The two conventions describe the same mechanism; nothing is
approximated. If you compare `qpos` between MuJoCo and Kinetic for the same file
the joint values agree — only the intermediate link frames differ, and only by a
constant translation.

## Multiple joints on one body

MuJoCo allows several joints on a single body (the classic three-hinge wrist).
Kinetic's model is one joint per link, so the importer inserts massless
intermediate links, named `body__jointname`, and the last one in the chain
carries the body's geometry and inertia.

The degrees of freedom, their order and their behaviour are unchanged. Only the
link count differs, which shows up in `kinetic info`.

## Mass and inertia

If `<inertial>` is present it is used directly, including `fullinertia` and a
rotated `<inertial quat>`.

Otherwise mass is accumulated from the geoms — `mass` if given, else
`density × volume` with `density` defaulting to 1000 kg/m³ — and the body's
inertia is the parallel-axis sum of the geoms' tensors about the combined centre
of mass. This matches MuJoCo's behaviour for the common case.

## `fromto`

Capsules and cylinders written as end points are converted to a centre, an
orientation and a half-length:

```xml
<geom type="capsule" fromto="0 0 0  0 0 0.6" size="0.02"/>
```

becomes a capsule of radius 0.02 and half-length 0.3, centred at (0, 0, 0.3) and
aligned with +Z. Verified in the test suite.

## `solref`

`solref="timeconst dampratio"` maps directly onto Kinetic's
`stiffnessTimeConstant` and `dampingRatio`, which use the same parameterisation.
A MuJoCo model's contact feel usually carries over without retuning.

## Collision filtering

`contype` becomes the geom's group and `conaffinity` its mask. `contype="0"`
makes a geom non-collidable — the usual way to mark visual-only geometry in MJCF.

## Not handled

- `<tendon>`, `<equality>`, `<sensor>`, `<keyframe>`, `<contact>` blocks
- `<flexcomp>`, deformables, composite objects
- `<texture>` and `<material>` assets (geoms use `rgba`)
- muscle and general actuators
- `<replicate>` and `<include>`

Unsupported elements are skipped rather than failing the import, so a model that
uses them still loads with its rigid-body content intact.
