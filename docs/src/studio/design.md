# Liquid Glass

Studio's chrome uses Apple's Liquid Glass material — `GlassEffectContainer`,
`.glassEffect(_:)`, `.buttonStyle(.glass)` and `glassEffectID` — on macOS 26, with
a deliberate fallback below it.

## Where glass is used, and where it is not

Glass is for **floating chrome over content**: the transport bar, the viewport
HUD and toolbar, the command palette, the Foxglove switch, panel filter bars.

It is not used for content surfaces. Telemetry plots, tables and trees sit on
opaque panels, because a refracting background behind a dense numeric grid costs
legibility and buys nothing.

One deliberate exception worth knowing: the segmented control's **track** stays
flat even on macOS 26. Glass inside glass double-refracts and the selection pill
loses its edge against its own container, so only the pill is glass.

## Merging

`GlassEffectContainer` is used where merging is the point — the toolbar, stat
rows, the segmented control. The selection pill carries both
`matchedGeometryEffect` (which moves the frame) and `glassEffectID` (which lets
the material stretch and re-form across the gap rather than cross-fading).

## The macOS 14 fallback

The package minimum is macOS 14, so every glass use is behind
`if #available(macOS 26.0, *)`. The fallback is meant to look deliberate rather
than broken, and it differs in six ways worth stating:

1. **No lensing or specular rim.** Real glass refracts the viewport behind it and
   draws its own bright edge. The fallback is `.ultraThinMaterial` plus an
   explicit hairline stroke that exists only to replace that missing edge.
2. **A fill behind the material.** `.ultraThinMaterial` over a bright 3D viewport
   blows out, so the fallback puts a dark (or light) fill behind it. Glass needs
   no such backing.
3. **The segmented selection slides rather than morphs** — same curve and
   geometry, translation instead of deformation.
4. **Buttons are a different control**: `.glass` with a tint above, a plain button
   with a hover wash and an accent border below. Active state reads through tint
   and border in both cases, because a solid fill punches a hole in a glass bar.
5. **Adjacent items do not fuse** — the containers degrade to plain stacks with
   identical spacing, so layout is unchanged.
6. **Focus tint is flat** rather than an interactive tint on live glass.

## Tokens

One accent (`#0070F3`), a four-step neutral ramp per appearance, one radius
scale, one type scale. Numbers are always monospaced with tabular figures, so a
column of telemetry does not reflow as values change.

The token layer aliases the existing palette rather than copying values, so a hue
change lands in exactly one place.

## Built from SwiftUI's own controls

Everything that has a native equivalent is the native control, styled — not a
reimplementation of it. Tables are `Table` with `KeyPathComparator` sorting and
`.searchable`; the inspector is a `Form` of `Section`s and `LabeledContent`;
plots are Swift Charts; the shell is `NavigationSplitView` with a real
`.inspector` and a real `.toolbar`; settings are a `Settings` scene; empty states
are `ContentUnavailableView`. Studio's own look lives in `ButtonStyle` and
`ToggleStyle` conformances, which is the extension point SwiftUI provides.

The reason is not purity. A hand-drawn checkbox looks identical until someone
tabs to it, right-clicks it, turns on Increase Contrast, or runs VoiceOver — and
then it is simply broken. Native controls arrive with all of that already true.

The one deliberate exception is the panel splitter. `HSplitView` and `VSplitView`
are backed by `NSSplitView` and Auto Layout, and nesting them to the depth a
panel tree reaches turns every display cycle into constraint solving. Studio's
split is a `Layout` conformance instead — still SwiftUI's own extension point,
but resolving alignment guides from the frame rather than by placing every child.

## What a live window is allowed to cost

The workspace shows numbers that change continuously, and every one of them is a
chance to re-lay out the window. Three rules keep that in hand.

**One tick.** Statistics, plot samples and the playhead all change while the
world runs. They are announced together, in one call stack, so the window lays
out once per tick instead of once per publisher.

**Scoped observation.** Fast-changing values live on their own small
`ObservableObject`s (`LiveStats`, `PlotStore`) rather than on the model every
view observes. An `ObservableObject` invalidates every observer, not only the
ones that read the property that changed.

**Rates matched to what is visible.** The tick runs at 10 Hz while stepping and
2 Hz while paused, and plots redraw a little slower still, because Charts rebuilds
its scales and marks from scratch each time.

Together these take an idle window from about a fifth of a core to under a
tenth, and a running one from roughly a full core to about a third.
