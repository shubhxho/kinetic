//
//  main.swift
//  kinetic
//
//  Command-line front end: run and benchmark scenes, inspect models, record and
//  replay logs, serve telemetry, and render headless frames.
//

import AppKit
import Foundation
import Kinetic
import KineticBridge
import KineticRender
import simd

// MARK: - Terminal helpers

enum Term {
    static let isTTY = isatty(STDOUT_FILENO) == 1
    static func style(_ text: String, _ code: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
    static func bold(_ t: String) -> String { style(t, "1") }
    static func dim(_ t: String) -> String { style(t, "2") }
    static func cyan(_ t: String) -> String { style(t, "36") }
    static func green(_ t: String) -> String { style(t, "32") }
    static func yellow(_ t: String) -> String { style(t, "33") }
    static func red(_ t: String) -> String { style(t, "31") }
}

struct Arguments {
    let command: String
    let positional: [String]
    private let flags: [String: String]
    private let switches: Set<String>

    init(_ raw: [String]) {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var switches: Set<String> = []
        var index = 0
        var command = "help"
        var rest = raw
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest.removeFirst()
        }
        while index < rest.count {
            let token = rest[index]
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if index + 1 < rest.count, !rest[index + 1].hasPrefix("--") {
                    flags[name] = rest[index + 1]
                    index += 2
                    continue
                }
                switches.insert(name)
            } else {
                positional.append(token)
            }
            index += 1
        }
        self.command = command
        self.positional = positional
        self.flags = flags
        self.switches = switches
    }

    func string(_ name: String) -> String? { flags[name] }
    func int(_ name: String) -> Int? { flags[name].flatMap(Int.init) }
    func double(_ name: String) -> Double? { flags[name].flatMap(Double.init) }
    func has(_ name: String) -> Bool { switches.contains(name) || flags[name] != nil }
}

func formatNumber(_ value: Double, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f", value)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

// MARK: - Model loading

func loadWorld(_ target: String) throws -> World {
    if let scene = SceneLibrary.build(target) { return scene }
    let url = URL(fileURLWithPath: target)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw CLIError.notFound(target)
    }
    switch url.pathExtension.lowercased() {
    case "urdf":
        return try URDF.load(contentsOf: url).world
    case "xml", "mjcf":
        return try MJCF.load(contentsOf: url).world
    default:
        // Sniff the root element so extensions do not have to be exact.
        let data = try Data(contentsOf: url)
        let text = String(data: data.prefix(4096), encoding: .utf8) ?? ""
        if text.contains("<mujoco") { return try MJCF.load(data: data).world }
        if text.contains("<robot") { return try URDF.load(data: data).world }
        throw CLIError.unsupported(url.pathExtension)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case notFound(String)
    case unsupported(String)
    case message(String)

    var description: String {
        switch self {
        case .notFound(let t): return "no scene or file named '\(t)'"
        case .unsupported(let e): return "unsupported file type '.\(e)'"
        case .message(let m): return m
        }
    }
}

// MARK: - Commands

func commandList() {
    print(Term.bold("Built-in scenes"))
    print()
    for entry in SceneLibrary.all {
        print("  \(Term.cyan(pad(entry.id, 12)))\(entry.title)")
        print("  \(pad("", 12))\(Term.dim(entry.summary))")
    }
    print()
    print(Term.dim("  Load your own with:  kinetic run path/to/robot.urdf"))
}

func commandInfo(_ arguments: Arguments) throws {
    guard let target = arguments.positional.first else {
        throw CLIError.message("usage: kinetic info <scene|file>")
    }
    let world = try loadWorld(target)
    world.forward()

    print(Term.bold("Model  ") + target)
    print()
    print("  articulations   \(world.articulationCount)")
    print("  links           \(world.linkCount)")
    print("  geoms           \(world.geomCount)")
    print("  coordinates nq  \(world.coordinateCount)")
    print("  degrees of freedom nv  \(world.dofCount)")
    print("  actuators       \(world.actuatorCount)")
    print("  sensor channels \(world.sensorDataCount)")
    print("  total mass      \(formatNumber(world.totalMass)) kg")
    print("  timestep        \(formatNumber(world.options.timestep * 1000)) ms")
    print()

    for a in 0..<world.articulationCount {
        let name = world.name(articulation: a)
        let links = world.linkCount(articulation: a)
        print(Term.bold("  \(name)") + Term.dim("  \(links) link\(links == 1 ? "" : "s")"))
        for l in 0..<links {
            let kind = world.jointKind(articulation: a, link: l)
            let parent = world.parent(articulation: a, link: l)
            let indent = String(repeating: "  ", count: parent < 0 ? 2 : 3)
            var line = "\(indent)\(world.name(articulation: a, link: l))"
            line = pad(line, 34)
            line += Term.dim(pad("\(kind)", 11))
            line += Term.dim("m=\(formatNumber(world.mass(articulation: a, link: l), 3))")
            if let limits = world.jointLimits(articulation: a, link: l) {
                line += Term.dim("  [\(formatNumber(limits.lowerBound, 2)), \(formatNumber(limits.upperBound, 2))]")
            }
            print(line)
        }
    }
}

func commandRun(_ arguments: Arguments) throws {
    guard let target = arguments.positional.first else {
        throw CLIError.message("usage: kinetic run <scene|file> [--duration s] [--record out.kinlog] [--serve] [--port 8765]")
    }
    let world = try loadWorld(target)
    let duration = arguments.double("duration") ?? 5.0
    let steps = arguments.int("steps") ?? Int(duration / world.options.timestep)

    var recorder: LogRecorder?
    if let path = arguments.string("record") {
        recorder = try LogRecorder(url: URL(fileURLWithPath: path), world: world, title: target)
        print(Term.dim("recording to \(path)"))
    }

    var bridge: FoxgloveBridge?
    if arguments.has("serve") {
        let port = UInt16(arguments.int("port") ?? 8765)
        let server = FoxgloveBridge(world: world)
        try server.start(port: port)
        bridge = server
        print(Term.green("telemetry ") + "ws://localhost:\(port)"
              + Term.dim("  (Foxglove: Open connection → Foxglove WebSocket)"))
    }

    let realtime = arguments.has("realtime")
    let start = Date()
    var lastReport = Date()
    let reportEvery = 0.5

    print(Term.bold("Running ") + target + Term.dim("  \(steps) steps @ \(formatNumber(world.options.timestep * 1000, 2)) ms"))

    for step in 0..<steps {
        world.step()
        recorder?.record(world)
        bridge?.publishIfNeeded()

        if realtime {
            let targetTime = world.time
            let elapsed = Date().timeIntervalSince(start)
            if targetTime > elapsed {
                Thread.sleep(forTimeInterval: targetTime - elapsed)
            }
        }
        if Date().timeIntervalSince(lastReport) > reportEvery {
            lastReport = Date()
            let profile = world.profile
            let wall = Date().timeIntervalSince(start)
            let rtf = world.time / max(wall, 1e-6)
            let line = "  t=\(padLeft(formatNumber(world.time, 2), 7))s"
                + "  rtf=\(padLeft(formatNumber(rtf, 1), 6))x"
                + "  step=\(padLeft(formatNumber(profile.total, 3), 6))ms"
                + "  contacts=\(padLeft("\(profile.contactCount)", 4))"
                + "  E=\(padLeft(formatNumber(world.totalEnergy, 2), 9))J"
            FileHandle.standardOutput.write(Data(("\r" + line).utf8))
            _ = step
        }
    }
    print()

    let wall = Date().timeIntervalSince(start)
    recorder?.finish()
    print()
    print(Term.bold("Done"))
    print("  simulated       \(formatNumber(world.time, 3)) s")
    print("  wall clock      \(formatNumber(wall, 3)) s")
    print("  realtime factor \(Term.green(formatNumber(world.time / max(wall, 1e-9), 1) + "x"))")
    print("  mean step       \(formatNumber(wall / Double(steps) * 1000, 4)) ms")
    if let recorder {
        print("  frames recorded \(recorder.frameCount)")
    }
    if bridge != nil {
        print()
        print(Term.dim("telemetry server still running — press Ctrl-C to exit"))
        RunLoop.main.run()
    }
}

func commandBench(_ arguments: Arguments) throws {
    let seconds = arguments.double("seconds") ?? 2.0
    let targets = arguments.positional.isEmpty
        ? SceneLibrary.all.map(\.id)
        : arguments.positional

    print(Term.bold("Kinetic benchmark") + Term.dim("  \(formatNumber(seconds, 1)) s of simulated time per scene"))
    print()
    print(Term.dim(pad("scene", 14) + padLeft("nv", 5) + padLeft("geoms", 7)
                   + padLeft("steps", 8) + padLeft("ms/step", 10) + padLeft("steps/s", 10)
                   + padLeft("realtime", 10) + padLeft("contacts", 10)))

    for target in targets {
        guard let world = SceneLibrary.build(target) ?? (try? loadWorld(target)) else { continue }
        let steps = Int(seconds / world.options.timestep)
        // Warm up so the first-touch page faults do not land in the measurement.
        world.step(min(50, steps))

        let start = Date()
        world.step(steps)
        let elapsed = Date().timeIntervalSince(start)
        let profile = world.profile

        let msPerStep = elapsed / Double(steps) * 1000
        let line = pad(target, 14)
            + padLeft("\(world.dofCount)", 5)
            + padLeft("\(world.geomCount)", 7)
            + padLeft("\(steps)", 8)
            + padLeft(formatNumber(msPerStep, 4), 10)
            + padLeft(formatNumber(1000 / max(msPerStep, 1e-9), 0), 10)
            + padLeft(formatNumber(seconds / elapsed, 1) + "x", 10)
            + padLeft("\(profile.contactCount)", 10)
        print(line)
    }
    print()
    print(Term.dim("  single-threaded, double precision, warm caches"))
}

func commandValidate(_ arguments: Arguments) throws {
    print(Term.bold("Physics validation"))
    print()
    var failures = 0

    func check(_ name: String, _ detail: String, _ passed: Bool) {
        let mark = passed ? Term.green("PASS") : Term.red("FAIL")
        print("  \(mark)  \(pad(name, 34))\(Term.dim(detail))")
        if !passed { failures += 1 }
    }

    // Free fall matches the exact semi-implicit Euler solution.
    do {
        let world = World()
        world.addRigidBody(name: "ball", shape: .sphere(radius: 0.1), density: 1000,
                           pose: Pose(position: Vec3(0, 0, 10)))
        world.compile()
        var options = world.options
        options.enableContacts = false
        world.options = options
        let h = options.timestep
        let n = 500
        world.step(n)
        let expected = 10 - 9.81 * h * h * Double(n) * Double(n + 1) / 2
        let error = abs(world.positions[2] - expected)
        check("free fall", "error \(formatNumber(error * 1e9, 2)) nm", error < 1e-9)
    }

    // A resting sphere should not sink past the configured slop.
    do {
        let world = World()
        world.addGround()
        world.addRigidBody(name: "ball", shape: .sphere(radius: 0.2), density: 500,
                           pose: Pose(position: Vec3(0, 0, 1)))
        world.compile()
        world.step(1500)
        let penetration = 0.2 - world.positions[2]
        check("resting contact", "penetration \(formatNumber(penetration * 1000, 3)) mm",
              penetration < world.options.penetrationSlop * 2 + 1e-6)
    }

    // Energy drift of an undamped pendulum over ten seconds.
    do {
        let world = World()
        let art = world.addArticulation(name: "pendulum")
        let link = world.addLink(articulation: art, parent: -1, name: "arm")
        world.setJoint(articulation: art, link: link,
                       JointSpec.revolute(axis: Vec3(1, 0, 0)))
        world.setInertial(articulation: art, link: link, mass: 1, com: Vec3(0, 0, -0.5),
                          inertia: [1.0 / 3, 0, 0, 0, 1.0 / 3, 0, 0, 0, 1e-4])
        world.setDefaultPose(articulation: art, q: [1.5])
        world.compile()
        var options = world.options
        options.timestep = 1.0 / 2000
        world.options = options
        world.forward()
        let before = world.totalEnergy
        world.step(20_000)
        world.forward()
        let drift = abs(world.totalEnergy - before) / max(abs(before), 1e-9)
        check("pendulum energy drift", "\(formatNumber(drift * 100, 3)) % over 10 s", drift < 0.01)
    }

    // Momentum is conserved for a collision-free floating body.
    do {
        let world = World()
        world.addRigidBody(name: "body", shape: .box(halfExtents: Vec3(0.2, 0.1, 0.05)),
                           density: 800, pose: Pose(position: Vec3(0, 0, 2)))
        world.compile()
        var options = world.options
        options.gravity = .zero
        options.enableContacts = false
        options.integrator = .rungeKutta4
        world.options = options
        world.setVelocity(articulation: 0, linear: Vec3(0.4, -0.2, 0.1),
                          angular: Vec3(2.0, 3.0, 1.0))
        world.forward()
        let before = world.angularMomentum
        world.step(4000)
        world.forward()
        let after = world.angularMomentum
        let error = (after - before).length / max(before.length, 1e-9)
        check("angular momentum (RK4)", "drift \(formatNumber(error * 100, 4)) %", error < 0.001)
    }

    // Coulomb friction: a box holds below the cone and slides above it.
    do {
        let world = World()
        world.addGround(friction: 1.0)
        let body = world.addRigidBody(name: "box", shape: .box(halfExtents: Vec3(0.1, 0.1, 0.1)),
                                      density: 500, pose: Pose(position: Vec3(0, 0, 0.1)))
        world.compile()
        world.step(200)
        for _ in 0..<200 {
            world.applyForce(articulation: body.articulation, link: 0, force: Vec3(20, 0, 0),
                             at: Vec3(0, 0, 0.1))
            world.step()
            world.clearAppliedForces()
        }
        let held = abs(world.positions[0])
        for _ in 0..<200 {
            world.applyForce(articulation: body.articulation, link: 0, force: Vec3(120, 0, 0),
                             at: Vec3(0, 0, 0.1))
            world.step()
            world.clearAppliedForces()
        }
        let slid = world.positions[0]
        check("Coulomb friction", "held \(formatNumber(held * 1000, 2)) mm, slid \(formatNumber(slid, 3)) m",
              held < 0.002 && slid > 0.1)
    }

    // A ten-box stack must stay stacked.
    do {
        let world = SceneLibrary.boxStack(count: 10)
        world.step(3000)
        var ordered = true
        var maxDrift = 0.0
        for i in 0..<10 {
            let z = world.positions[i * 7 + 2]
            let expected = 0.1 + 0.2 * Double(i)
            maxDrift = max(maxDrift, abs(z - expected))
            if abs(z - expected) > 0.02 { ordered = false }
        }
        check("box stack stability", "max drift \(formatNumber(maxDrift * 1000, 2)) mm", ordered)
    }

    // Determinism: the same inputs must produce bit-identical state.
    do {
        func run() -> [Double] {
            let world = SceneLibrary.mixedPrimitives()
            world.step(600)
            return Array(world.positions)
        }
        let a = run(), b = run()
        check("determinism", "\(a.count) coordinates compared", a == b)
    }

    print()
    if failures == 0 {
        print(Term.green("  all checks passed"))
    } else {
        print(Term.red("  \(failures) check\(failures == 1 ? "" : "s") failed"))
        exit(1)
    }
}

func commandRender(_ arguments: Arguments) throws {
    guard let target = arguments.positional.first else {
        throw CLIError.message("usage: kinetic render <scene|file> --out frame.png [--steps N]")
    }
    let world = try loadWorld(target)
    let steps = arguments.int("steps") ?? 0
    if steps > 0 { world.step(steps) }

    guard let renderer = Renderer(sampleCount: 4) else {
        throw CLIError.message("no Metal device available")
    }
    var settings = RenderSettings()
    settings.theme = arguments.has("light") ? .light : .dark
    settings.showContacts = !arguments.has("no-contacts")

    var camera = OrbitCamera()
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for pose in world.linkPoses() {
        let p = SIMD3<Float>(Float(pose.position.x), Float(pose.position.y), Float(pose.position.z))
        lo = simd_min(lo, p - SIMD3<Float>(repeating: 0.12))
        hi = simd_max(hi, p + SIMD3<Float>(repeating: 0.12))
    }
    if lo.x <= hi.x { camera.frame(min: lo, max: hi) }

    let width = arguments.int("width") ?? 1600
    let height = arguments.int("height") ?? 1000
    guard let image = renderer.snapshot(world: world, settings: settings, camera: camera,
                                        width: width, height: height) else {
        throw CLIError.message("render failed")
    }
    let output = URL(fileURLWithPath: arguments.string("out") ?? "kinetic-frame.png")
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CLIError.message("PNG encoding failed")
    }
    try data.write(to: output)
    print(Term.green("wrote ") + output.path + Term.dim("  \(width)x\(height)"))
}

func commandReplay(_ arguments: Arguments) throws {
    guard let path = arguments.positional.first else {
        throw CLIError.message("usage: kinetic replay <file.kinlog> [--csv out.csv]")
    }
    let player = try LogPlayer(url: URL(fileURLWithPath: path))
    print(Term.bold("Recording  ") + player.header.title)
    print()
    print("  engine        \(player.header.engineVersion)")
    print("  recorded      \(player.header.createdAt)")
    print("  frames        \(player.frameCount)")
    print("  duration      \(formatNumber(player.duration, 3)) s")
    print("  timestep      \(formatNumber(player.header.timestep * 1000, 3)) ms")
    print("  nq / nv       \(player.header.coordinateCount) / \(player.header.dofCount)")
    print("  geoms         \(player.header.geoms.count)")
    print("  channels      \(player.availableChannels.count)")

    if let csv = arguments.string("csv") {
        let channels = player.availableChannels
        try player.exportCSV(channels: channels, to: URL(fileURLWithPath: csv))
        print()
        print(Term.green("exported ") + csv + Term.dim("  \(channels.count) channels x \(player.frameCount) frames"))
    }
}

func commandServe(_ arguments: Arguments) throws {
    let target = arguments.positional.first ?? "arm"
    let world = try loadWorld(target)
    let port = UInt16(arguments.int("port") ?? 8765)
    let bridge = FoxgloveBridge(world: world)
    bridge.publishRate = arguments.double("rate") ?? 30
    bridge.onLog = { print(Term.dim("  [bridge] " + $0)) }
    try bridge.start(port: port)

    print(Term.bold("Kinetic telemetry"))
    print()
    print("  scene    \(target)")
    print("  address  \(Term.cyan("ws://localhost:\(port)"))")
    print("  protocol foxglove.websocket.v1")
    print("  topics   /kinetic/scene, /kinetic/contacts, /kinetic/tf, /kinetic/state,")
    print("           /kinetic/profile, /kinetic/sensors")
    print()
    print(Term.dim("  Foxglove: Open connection → Foxglove WebSocket → paste the address."))
    print(Term.dim("  Ctrl-C to stop."))
    print()

    let timestep = world.options.timestep
    let queue = DispatchQueue(label: "com.kinetic.cli.sim")
    queue.async {
        var next = CACurrentMediaTimeShim()
        while true {
            world.step()
            bridge.publishIfNeeded()
            next += timestep
            let now = CACurrentMediaTimeShim()
            if next > now {
                Thread.sleep(forTimeInterval: next - now)
            } else if now - next > 0.5 {
                next = now  // fell too far behind; resynchronise
            }
        }
    }
    RunLoop.main.run()
}

func commandHelp() {
    print("""
    \(Term.bold("kinetic")) \(Term.dim(World.versionString))
    Native macOS robotics simulation.

    \(Term.bold("USAGE"))
      kinetic <command> [arguments]

    \(Term.bold("COMMANDS"))
      \(Term.cyan("list"))                       show the built-in scenes
      \(Term.cyan("info"))     <scene|file>      print the model tree and mass properties
      \(Term.cyan("run"))      <scene|file>      simulate, optionally recording or serving
      \(Term.cyan("bench"))    [scene...]        measure step cost across scenes
      \(Term.cyan("validate"))                   run the physics validation suite
      \(Term.cyan("render"))   <scene|file>      render a frame to PNG, headless
      \(Term.cyan("replay"))   <file.kinlog>     inspect or export a recording
      \(Term.cyan("serve"))    <scene|file>      stream live telemetry over WebSocket

    \(Term.bold("OPTIONS"))
      --duration <s>      simulated seconds for `run` (default 5)
      --steps <n>         explicit step count
      --realtime          pace `run` to wall-clock time
      --record <path>     write a .kinlog recording
      --serve             also start the telemetry server
      --port <n>          telemetry port (default 8765)
      --rate <hz>         telemetry publish rate (default 30)
      --out <path>        output file for `render`
      --width/--height    render size (default 1600x1000)
      --light             render with the light theme
      --csv <path>        export every channel of a recording

    \(Term.bold("EXAMPLES"))
      kinetic bench
      kinetic run quadruped --duration 10 --record walk.kinlog
      kinetic serve arm --port 8765
      kinetic render stack --steps 400 --out stack.png
      kinetic info ~/models/panda.urdf
    """)
}

// MARK: - Entry point

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))

do {
    switch arguments.command {
    case "list": commandList()
    case "info": try commandInfo(arguments)
    case "run": try commandRun(arguments)
    case "bench", "benchmark": try commandBench(arguments)
    case "validate", "verify": try commandValidate(arguments)
    case "render", "screenshot": try commandRender(arguments)
    case "replay", "log": try commandReplay(arguments)
    case "serve": try commandServe(arguments)
    case "version", "--version": print(World.versionString)
    default: commandHelp()
    }
} catch {
    FileHandle.standardError.write(Data((Term.red("error: ") + "\(error)\n").utf8))
    exit(1)
}
