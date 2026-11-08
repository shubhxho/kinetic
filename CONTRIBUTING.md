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
```

Those four are the landing bar on macOS. This repository's physics core is
portable C++; the renderer, CLI and Studio are not.

```bash
mdbook serve docs --open
```
