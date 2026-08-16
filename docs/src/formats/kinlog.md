# The `.kinlog` recording format

A recording is self-describing: it carries the whole model description in its
header, so a log can be replayed, plotted and re-rendered without the original
scene file.

## Writing

```swift
let recorder = try LogRecorder(url: url, world: world, title: "walk trial 3")
for _ in 0..<5000 {
    world.step()
    recorder.record(world)
}
recorder.finish()
```

Or from the CLI and Studio:

```bash
kinetic run quadruped --duration 10 --record walk.kinlog
```

Writes are buffered and flushed at 1 MB, so recording costs a few percent of step
time.

## Reading

```swift
let player = try LogPlayer(url: url)

player.header.title
player.frameCount
player.duration
player.header.geoms          // enough to render without the source model

let frame = try player.frame(at: 120)
frame.positions
frame.contacts
frame.linkPoses              // 7 floats per link: xyz + wxyz

let index = player.index(forTime: 3.5)      // binary search
```

`LogPlayer` memory-maps the file and indexes frame offsets on open, so seeking is
constant-time and a multi-gigabyte log does not need to fit in RAM.

## Channels

```swift
for channel in player.availableChannels {
    print(channel.label)      // "qvel[3]", "imu_gyro.x", "step time (ms)", ...
}

let (times, values) = try player.channel(someChannel)
try player.exportCSV(channels: player.availableChannels, to: csvURL)
```

Channels cover joint coordinates, velocities, control inputs, every sensor
component by name, step time, contact count and total normal force.

## Layout

```text
offset  size      content
0       6         magic "KNLOG\0"
6       4         version, uint32 little-endian
10      8         header length, uint64
18      n         header, JSON (UTF-8)
18+n    ...       frames

frame:
  4     magic "FRAM" (0x4D415246)
  8     time, float64
  4     payload length, uint32
  ...   payload

payload:
  nq × float64    qpos
  nv × float64    qvel
  nu × float64    ctrl
  ns × float64    sensor data
  nlink × 7 × float32   link poses (position, then quaternion w,x,y,z)
  4               contact count, uint32
  per contact:
    10 × float64  point(3), normal(3), force(3), depth
    2  × int32    geomA, geomB
  8               step time in milliseconds, float64
```

Little-endian throughout. Link poses are float32 because they are render data;
everything the physics depends on is float64.

## The header

```json
{
  "version": 1,
  "createdAt": "2026-08-16T12:00:00Z",
  "title": "walk trial 3",
  "timestep": 0.002,
  "gravity": [0, 0, -9.81],
  "coordinateCount": 20,
  "dofCount": 18,
  "actuatorCount": 12,
  "sensorDataCount": 10,
  "linkCount": 14,
  "linkNames": ["quadruped.torso", "quadruped.fl_hip", "..."],
  "sensorNames": ["fl_contact", "imu_gyro", "imu_accel"],
  "sensorDimensions": [1, 3, 3],
  "geoms": [
    {"name": "torso", "kind": 1, "size": [0.24, 0.11, 0.055],
     "color": [0.16, 0.17, 0.2, 1], "metallic": 0.2, "roughness": 0.4,
     "articulation": 1, "link": 0, "visible": true}
  ],
  "engineVersion": "Kinetic 1.0.0"
}
```

Because `geoms` carries shape, size, colour and link binding, a player can
reconstruct the scene for rendering from the log alone.

## Why not MCAP or rosbag

MCAP is a good general container and Kinetic can publish into that ecosystem
through the [Foxglove bridge](../telemetry/foxglove.md). But a general container
stores opaque per-topic blobs, and the thing worth optimising here is different:
every frame has *identical* structure, and what you want is O(1) seeking into
full simulation state.

A fixed-layout payload gives that with no schema negotiation, no per-message
framing overhead, and a file that can be `mmap`-ed and indexed in a single pass.

Use `.kinlog` for the inner loop and the bridge for interoperability.

## Inspecting from the CLI

```bash
kinetic replay walk.kinlog
kinetic replay walk.kinlog --csv walk.csv
```
