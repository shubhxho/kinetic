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
kinetic run <scene|file> --duration 10        # simulate
kinetic run <scene> --realtime --serve        # realtime, with telemetry
kinetic bench                                 # benchmark every scene
kinetic bench --serial                        # single-threaded comparison
kinetic validate                              # physics validation suite
kinetic render <scene> --out frame.png        # headless render
kinetic replay <file.kinlog> --csv out.csv    # inspect or export a recording
kinetic serve <scene> --port 8765             # telemetry server
```
