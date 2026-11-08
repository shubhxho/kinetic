# Kinetic Studio

Studio is the native application. It owns a world, steps it from the display
link, and gives you the instruments to work out what the physics is doing.

```bash
./Scripts/bundle-app.sh release
open "dist/Kinetic Studio.app"
```

`swift build` produces `.build/release/KineticStudio`, a bare Mach-O. macOS
needs an `Info.plist` and the usual directory layout before a binary can own a
Dock icon, a menu bar and keyboard focus, so the script assembles
`dist/Kinetic Studio.app` and copies the `kinetic` CLI into it.

## Layout

The window is SwiftUI's own shell: `NavigationSplitView` for the sidebar,
`.inspector` for the trailing pane, `.toolbar` for transport, and a stacked
detail column for the panel host, timeline and status bar. That is the layout
in `ContentView` after the native-controls rebuild.

```text
+---------------------------------------------------------------------+
|  title · n dof · n links     play  step  reset   0.1x 0.25x 1x 2x   |
|                                  layout  frame  Foxglove  cmd  Open | toolbar
+------------+----------------------------------------+---------------+
|            |  HUD: time  rtf  step  contacts  fps   |               |
|  scene     |                                        |  inspector    |
|  tree      |     panel host (viewport by default)   |  (Form)       |
|            |                              <gizmo>   |               |
|            +----------------------------------------+               |
|            | timeline  t = 1.482 s     20.0 s window|               |
|            +----------------------------------------+               |
|            | status  nq nv links geoms   fps  ver   |               |
+------------+----------------------------------------+---------------+
```

The default **Simulate** preset puts a scene tree, viewport, plot, inspector
and joint panel in the split tree. Switch presets from the layout menu in the
toolbar (Simulate, Analyse, Debug, Foxglove). Split, close and change panel
type from that menu or the panel header. See
[Panels and workspaces](../studio/workspace.md).

Open (`⌘O`) is URDF and MJCF. USD is not in that dialog.

## The timeline

The bar under the panel host is the part worth learning first.

Studio snapshots the **entire simulation state** after every step into a rolling
window, twenty seconds by default, sized automatically from the model's
timestep. Dragging the playhead restores those states directly. Nothing is
re-simulated, so what you see is exactly what happened, including the contact
set and the solver's own numbers.

The profile drawn behind the playhead is contact count over time, so you can see
where something touched before dragging to it.

While you are scrubbing the simulation is paused and a banner says so. Press
**Jump to live** to return to the newest state and hand control back.

> Scrubbing costs memory: one state is `(nq + nv + 1)` doubles. A 60-dof scene at
> 500 Hz over 20 seconds is roughly 18 MB. The status line on the right of the
> timeline shows the current figure. The window length is in Settings (`⌘,`).

## Command palette

`⌘K` opens a searchable list of every action: switching scenes, transport,
display toggles, starting the telemetry server, opening a model, recording.
Arrow keys navigate, `return` runs, `esc` closes.

## Panels

**Scene tree** (sidebar). Built-in scenes at the top, and below them the loaded
model as an articulation → link tree. Joint kinds are tagged
`rev`/`pri`/`sph`/`free`. Clicking a link selects its geometry, which highlights
it in the viewport with a rim light.

**Inspector** (trailing column). Live simulation and energy readouts, the current
selection's shape and mass properties, solver parameters you can change while
running (timestep, iteration count, gravity, warm starting), every display
toggle, and the telemetry server's status.

**Plot.** Live channels. The picker lists joint positions and velocities, control
inputs, actuator forces, each sensor component, step time, contact count, solver
residual, total energy, centre-of-mass height.

**Joints.** One slider per scalar joint, writing directly into `qpos` and
re-running forward kinematics. Pause, drag, watch the link move: that is how
you check an imported URDF's axes.

**Actuators.** One slider per actuator over its control range, with the resulting
force in newtons beside it.

**Log.** Timestamped events: scene loads, import warnings, recording start and
stop, telemetry connections.

Twelve kinds in total, including raw messages, table, state transitions,
diagnostics and ML insights. They live in the panel host, not in a fixed bottom
tab strip.

## Viewport controls

Mouse, when the Metal view has focus:

| Input | Action |
| --- | --- |
| drag | orbit |
| `⌘`/`⌥` + drag, or right-drag | pan |
| scroll | zoom |
| `⇧` + scroll | pan |
| pinch | zoom |
| click | select the geom under the cursor |

Keys, handled by `KineticView.keyDown` when the viewport is first responder:

| Key | Action |
| --- | --- |
| `space` | play / pause |
| `.` | single step |
| `F` | frame the scene |
| `G` | toggle grid |
| `C` | toggle contact points and forces |
| `K` | toggle collision geometry |
| `W` | toggle wireframe |
| `T` | toggle motion trails |

Selection uses the same `raycast` the physics API exposes, so what the viewport
picks and what a sensor ray would hit are the same thing.

## Recording

The record button (or `⌘⇧R`) writes a `.kinlog`: a self-describing, seekable
log containing the full model description plus per-frame state, contacts and
step timings. It can be replayed, plotted or exported to CSV later without the
original scene file. See [the format](../formats/kinlog.md).

## Serving telemetry

The Foxglove control in the toolbar starts the WebSocket server on the port in
Settings (default 8765). Point Foxglove at `ws://localhost:8765` and the scene
appears in its 3D panel with a live TF tree.
See [Connecting Foxglove](../telemetry/foxglove.md).
