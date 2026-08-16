# Kinetic Studio

Studio is the native application. It owns a world, steps it from the display
link, and gives you the instruments to work out what the physics is doing.

```bash
./Scripts/bundle-app.sh release
open "dist/Kinetic Studio.app"
```

## Layout

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ ▸ ⏸ ↺  0.1× 0.25× 1× 2×   ⌖ ISO FRO SID TOP    ⌘K search    ⏺ 📡 ◐ ▤ ▥ ▦ │  toolbar
├───────────┬──────────────────────────────────────────────┬───────────────┤
│           │  time  realtime  step  contacts  fps         │               │
│  scenes   │                                              │  simulation   │
│           │                                              │  energy       │
│  ─────    │                 viewport                     │  selection    │
│           │                                              │  solver       │
│  model    │                                              │  display      │
│  tree     │                                    ⟨gizmo⟩   │  telemetry    │
├───────────┴──────────────────────────────────────────────┴───────────────┤
│ ⏮ ◀ ▶ ▶ ⏭   1.482 s                        3910 frames · 20.0 s · 18 MB  │  timeline
│ ▁▂▅█▅▂▁▁▂▅███▅▂▁▁▁▂▃▅▅▃▂▁▁▁▁▂▅█████▅▂▁▁▁▁▁▂▃▅▃▂▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁│
├──────────────────────────────────────────────────────────────────────────┤
│ Telemetry │ Joints │ Actuators │ Log                                     │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐                             │
│ │ step time  │ │ contacts   │ │ com height │                             │
│ └────────────┘ └────────────┘ └────────────┘                             │
├──────────────────────────────────────────────────────────────────────────┤
│ ● running   13 nq · 12 nv · 7 links   ws://localhost:8765 · 1 client     │  status
└──────────────────────────────────────────────────────────────────────────┘
```

## The timeline

The bar under the viewport is the part worth learning first.

Studio snapshots the **entire simulation state** after every step into a rolling
window — twenty seconds by default, sized automatically from the model's
timestep. Dragging the playhead restores those states directly. Nothing is
re-simulated, so what you see is exactly what happened, including the contact
set and the solver's own numbers.

The profile drawn behind the playhead is contact count over time, so you can see
where something touched before dragging to it.

While you are scrubbing the simulation is paused and a banner says so. Press
**Jump to live** (or `⏭`) to return to the newest state and hand control back.

> Scrubbing costs memory: one state is `(nq + nv + 1)` doubles. A 60-dof scene at
> 500 Hz over 20 seconds is roughly 18 MB. The status line on the right of the
> timeline shows the current figure.

## Command palette

`⌘K` opens a searchable list of every action: switching scenes, transport,
display toggles, starting the telemetry server, opening a model, recording.
Arrow keys navigate, `return` runs, `esc` closes.

## Panels

**Scenes and model tree** (left). The built-in scenes at the top, and below them
the loaded model as an articulation → link tree. Joint kinds are tagged
`rev`/`pri`/`sph`/`free`. Clicking a link selects its geometry, which highlights
it in the viewport with a rim light.

**Inspector** (right). Live simulation and energy readouts, the current
selection's shape and mass properties, solver parameters you can change while
running (timestep, iteration count, gravity, warm starting), every display
toggle, and the telemetry server's status.

**Telemetry** (bottom). Live plots. `+ Channel` lists everything the running
model exposes: joint positions and velocities, control inputs, actuator forces,
each sensor component, step time, contact count, solver residual, total energy,
centre-of-mass height. The window buttons switch between 2 s, 8 s and 30 s.

**Joints** (bottom). One slider per scalar joint, writing directly into `qpos`
and re-running forward kinematics. This is how you check that an imported URDF's
axes and limits are what you meant — pause, drag, watch the link move.

**Actuators** (bottom). One slider per actuator over its control range, with the
resulting force in newtons beside it.

**Log** (bottom). Timestamped events: scene loads, import warnings, recording
start and stop, telemetry connections.

## Viewport controls

| Input | Action |
| --- | --- |
| drag | orbit |
| `⌘`/`⌥` + drag, or right-drag | pan |
| scroll | zoom |
| `⇧` + scroll | pan |
| pinch | zoom |
| click | select the geom under the cursor |

Selection uses the same `raycast` the physics API exposes, so what the viewport
picks and what a sensor ray would hit are the same thing.

## Recording

The record button (or `⌘⇧R`) writes a `.kinlog` — a self-describing, seekable
log containing the full model description plus per-frame state, contacts and
step timings. It can be replayed, plotted or exported to CSV later without the
original scene file. See [the format](../formats/kinlog.md).

## Serving telemetry

The antenna button starts the WebSocket server on port 8765. Point Foxglove at
`ws://localhost:8765` and the scene appears in its 3D panel with a live TF tree.
See [Connecting Foxglove](../telemetry/foxglove.md).
