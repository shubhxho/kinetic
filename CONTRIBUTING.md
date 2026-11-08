# Contributing

Build, test, and documentation conventions live in
[docs/src/contributing.md](docs/src/contributing.md). That chapter is part of
the [mdBook](https://shubhxho.github.io/kinetic/contributing.html).

Short version:

```bash
swift build -c release
swift test
./.build/release/kinetic validate
./.build/release/kinetic bench
./Scripts/bench-core.sh --check --seconds 1
```

The first four are the landing bar on macOS. `bench-core.sh` is the landing bar
for the portable C++ core: it compiles KineticCore and asserts scene sizes,
contact character, determinism and a coarse cost ordering. The renderer, CLI
and Studio still need a Mac.

```bash
mdbook serve docs --open
```
