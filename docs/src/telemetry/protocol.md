# Wire protocol

Kinetic implements the server half of
[`foxglove.websocket.v1`](https://github.com/foxglove/ws-protocol) on a
hand-written RFC 6455 stack.

## Why hand-written

Network.framework ships `NWProtocolWebSocket`, but two requirements pushed the
implementation down a layer:

- **Subprotocol negotiation.** The Foxglove handshake requires the server to echo
  `Sec-WebSocket-Protocol: foxglove.websocket.v1`. Doing that reliably means
  seeing the client's request headers and controlling the response.
- **Backpressure policy.** Telemetry should drop frames when a client falls
  behind, not queue them without bound. That decision has to be made per
  connection, at the point of send.

The result is about 300 lines on `NWListener` TCP: handshake, framing, masking,
ping/pong and close.

## Handshake

Standard RFC 6455. The server computes

```text
base64(SHA1(Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

and replies `101 Switching Protocols` with the accept token and, when the client
requested it, the negotiated subprotocol.

## Framing

Server-to-client frames are unmasked; client-to-server frames are masked and
unmasked on receipt, as the RFC requires. All three payload-length encodings
(7-bit, 16-bit, 64-bit) are implemented, and a partial frame decodes to nothing
without consuming bytes so a split TCP read resumes cleanly. The test suite
covers every length class, partial frames and masked frames.

## Session

On connect the server sends two text messages.

**`serverInfo`**

```json
{
  "op": "serverInfo",
  "name": "Kinetic",
  "capabilities": ["clientPublish"],
  "supportedEncodings": ["json"],
  "metadata": {"engine": "Kinetic 1.0.0"},
  "sessionId": "1755331200"
}
```

**`advertise`**

```json
{
  "op": "advertise",
  "channels": [
    {"id": 1, "topic": "/kinetic/scene", "encoding": "json",
     "schemaName": "foxglove.SceneUpdate", "schemaEncoding": "jsonschema",
     "schema": "{...}"}
  ]
}
```

The client subscribes:

```json
{"op": "subscribe", "subscriptions": [{"id": 0, "channelId": 1}]}
```

and from then on receives binary message-data frames:

```text
byte 0        0x01
bytes 1–4     subscription id,  uint32 little-endian
bytes 5–12    timestamp in nanoseconds, uint64 little-endian
bytes 13+     payload (JSON)
```

Only subscribed channels are encoded. Publishing nothing costs nothing.

## Client publish

A client advertises its own channel and sends:

```text
byte 0        0x01
bytes 1–4     channel id, uint32 little-endian
bytes 5+      payload (JSON)
```

Kinetic interprets two shapes:

```json
{"control": [0.1, 0.2, 0.3]}
{"index": 2, "value": 0.3}
```

Both write into `world.control`. Out-of-range indices are ignored rather than
trapping.

## Encoding

JSON, built by direct string construction rather than `JSONSerialization` —
serialising several hundred geoms per frame through a general encoder showed up
in the step budget. Doubles are formatted with `%.6g`, which is well inside
float32 rendering precision and keeps frames small.

CBOR and protobuf are natural extensions; the channel descriptor already carries
an encoding field.

## Threading

The listener and every connection run on one serial queue. `publishIfNeeded` is
called from the simulation thread and hops onto that queue, so the simulation
never blocks on a socket.

The subscription table is guarded by a lock and snapshotted before each publish,
so a client connecting mid-frame cannot tear the iteration.

## Writing another client

Nothing here is Foxglove-specific beyond the schema names. A minimal Python
client:

```python
import asyncio, json, struct, websockets

async def main():
    async with websockets.connect(
        "ws://localhost:8765", subprotocols=["foxglove.websocket.v1"]
    ) as ws:
        await ws.recv()                                  # serverInfo
        advertise = json.loads(await ws.recv())          # advertise
        state = next(c for c in advertise["channels"]
                     if c["topic"] == "/kinetic/state")
        await ws.send(json.dumps({
            "op": "subscribe",
            "subscriptions": [{"id": 0, "channelId": state["id"]}],
        }))
        while True:
            frame = await ws.recv()
            if isinstance(frame, bytes) and frame[0] == 1:
                payload = json.loads(frame[13:])
                print(payload["time"], payload["qpos"][:3])

asyncio.run(main())
```
