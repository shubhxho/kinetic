# Panels and workspaces

Studio's window is a **binary-split layout tree**, the same model Foxglove uses:
every panel is a leaf, every divider is a split with a fraction, and any panel can
become two.

## Working with panels

| Action | How |
| --- | --- |
| split right | `⌘\` or the panel header menu |
| split down | `⌘⇧\` |
| close | `⌘W` (never closes the last one) |
| change type | the panel header's type menu |
| move focus | `⌥⌘]` / `⌥⌘[` |
| resize | drag any divider |

Each panel header is 22 pt, secondary-coloured, and strengthens on hover — it is
chrome, not content.

## Panel kinds

| Kind | Shows |
| --- | --- |
| **3D Viewport** | the Metal render, with HUD, gizmo and measurement tool |
| **Plot** | live channel plots with a channel picker |
| **Raw Messages** | an inspectable tree of the entire world state |
| **Table** | sortable, filterable rows: geoms, links, contacts, actuators or sensors |
| **State Transitions** | when discrete conditions were true, over recorded history |
| **Diagnostics** | a health board with thresholds and one-line diagnoses |
| **Log** | timestamped events |
| **Joints** | one slider per scalar joint, writing straight into `qpos` |
| **Actuators** | one slider per actuator, with the resulting force |
| **Scene Tree** | articulation → link hierarchy |
| **Inspector** | selection, solver parameters, display toggles, telemetry |
| **ML Insights** | anomalies, correlations and run summaries |

## Presets

Four built-in workspaces, switchable from the toolbar:

- **Simulate** — viewport, inspector, telemetry. The default.
- **Analyse** — a plot-heavy grid for reading a run.
- **Debug** — viewport, raw messages, diagnostics and log together.
- **Foxglove** — a 2×2 grid mirroring a default Foxglove workspace.

Layouts persist as JSON in `UserDefaults` under a versioned key, and a decode
failure falls back to a builtin rather than crashing.

## Raw Messages

The equivalent of Foxglove's Raw Messages panel, for a simulator: an expandable
tree over state (`qpos`/`qvel`/`ctrl`/actuator forces, grouped per articulation
with joint names), contacts (point, normal, force, depth, and both geom names),
sensors (grouped, with component labels), and the step profile.

It stays responsive at several hundred rows because rows carry raw `Double`s and
formatting happens in the row body — so `String(format:)` runs only for rows
`LazyVStack` actually realises. A filter matches on path *and* label, force-opens
the tree, and prunes branches with no matching descendant.

## State Transitions

Horizontal timelines of when conditions held, drawn from the recorded history:
"in contact", "step over budget" (step time above the timestep), and contact-count
bands.

It aggregates per **pixel column** with `max` rather than per frame, so a single
over-budget step in a hundred still paints its column instead of being sampled
away. Hovering reads out every track; clicking scrubs the timeline.

## Diagnostics

Eight rows — solver residual, iterations used against configured, contacts,
constraints, broadphase pairs, energy drift since reset, realtime factor,
telemetry status — each with a status dot, a sparkline, and a diagnosis when it is
not healthy.

Every threshold is justified in a comment at the point of use, and every
diagnosis names a knob that actually exists. The broadphase row deliberately
reports a factual pair-to-contact ratio instead of inventing a knob, because the
tuning table has none for it.
