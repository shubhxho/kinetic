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
