# Keyboard shortcuts

## Studio

### Global

| Key | Action |
| --- | --- |
| `⌘K` | command palette |
| `⌘O` | open a URDF or MJCF model |
| `⌘⇧R` | start or stop recording |
| `⌘,` | preferences |
| `⌘W` | close window |

### Viewport

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

### Mouse

| Input | Action |
| --- | --- |
| drag | orbit |
| `⌘`/`⌥` + drag | pan |
| right-drag | pan |
| scroll | zoom |
| `⇧` + scroll | pan |
| pinch | zoom |
| click | select the geom under the cursor |

### Command palette

| Key | Action |
| --- | --- |
| `↑` `↓` | move selection |
| `return` | run |
| `esc` | close |

## CLI

```bash
kinetic list                                  # built-in scenes
kinetic info <scene|file>                     # model tree and mass properties
kinetic config                                # resolved flags, env, defaults
kinetic run <scene|file> --duration 10        # simulate
kinetic run <scene> --realtime --serve        # realtime, with telemetry
kinetic bench                                 # benchmark every scene
kinetic bench --serial                        # single-threaded comparison
./Scripts/bench-core.sh --check --seconds 1   # KineticCore, no Swift needed
./Scripts/bench-core.sh --config              # dump resolved KineticCore knobs
kinetic validate                              # physics validation suite
kinetic render <scene> --out frame.png        # headless render (Metal)
kinetic replay <file.kinlog> --csv out.csv    # inspect or export a recording
kinetic serve <scene> --port 8765             # telemetry server
kinetic models list                           # published robot registry
kinetic models fetch unitree-go2              # cache from upstream
kinetic models validate unitree-go2           # import report
```

Viewport keys (`space`, `.`, `F`, `G`, `C`, `K`, `W`, `T`) are handled by
`KineticView.keyDown` when the Metal view is first responder. Panel split/close
keys are listed in some older notes; the running app exposes those actions from
the toolbar layout menu. See [Panels and workspaces](../studio/workspace.md).
