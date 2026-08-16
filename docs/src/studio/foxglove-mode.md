# Foxglove mode

Kinetic both **serves** and **consumes** the Foxglove WebSocket protocol. The
switch in the toolbar flips the whole app between its native workspace and a
Foxglove-compatible one — layout, vocabulary and transport together.

## The switch

| State | What happens |
| --- | --- |
| off | native workspace, Kinetic's own vocabulary |
| on, source = local | starts the bridge, applies the Foxglove workspace preset |
| on, source = remote | connects the client to a remote server and subscribes |

The vocabulary is a value, not hard-coded strings: with the switch on, channels
become "topics", layouts become "workspaces", panels stay "panels". Views read it
from the environment, so nothing has to know which mode it is in.

## Consuming a remote simulation

Studio can now attach to a Kinetic instance running on another machine:

```swift
let client = FoxgloveClient()
client.connect(to: URL(string: "ws://192.168.1.40:8765")!)
client.subscribe(to: "/kinetic/state")
client.publishControl([0.0, -0.8, 1.6])
```

`FoxgloveClient` parses `serverInfo` and `advertise`, exposes the channel list,
decodes the binary message-data framing, and publishes control back through a
client-advertised channel — which is exactly what
[the server](../telemetry/foxglove.md) already accepts.

Typed payloads are decoded into Codable structs for the topics Kinetic itself
publishes, with an opaque `Data` for anything else. Every field decodes with a
default, so a version-skewed peer loses a field rather than the whole frame.

Subscription intent survives reconnects and is replayed on the next `advertise`.

## The client half of RFC 6455

The server was already hand-written; the client adds what a client needs:

- a random 16-byte `Sec-WebSocket-Key`, and **verification** that the server's
  `Sec-WebSocket-Accept` is the expected SHA-1 — it fails loudly with both values
  rather than proceeding on an unverified handshake;
- rejection of a 101 that names a subprotocol we never offered;
- **masked** client-to-server frames, which the server path does not need;
- a handshake deadline, so a silent peer still triggers a retry;
- exponential backoff with jitter, capped and cancellable.

Frame encoding and decoding are reused from the server, so the 7/16/64-bit length
rules exist in exactly one place.

> Randomness here — the key and the frame masks — is the one place in this
> repository where nondeterminism is correct, and it comes from a cryptographic
> source.

## The integration test

Point Studio's client at Studio's own server: start the bridge on 8765, connect
to `ws://localhost:8765`, and you should see six channels, `/kinetic/state`
arriving, and `publishControl` moving the world.

That round trip exercises the handshake, the accept-token check, masking, and both
binary framings at once, which is why it is the stated test rather than a mock.
