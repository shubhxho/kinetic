//
//  Recording.swift
//  Kinetic
//
//  The `.kinlog` recording format: a self-describing, seekable log of simulation
//  state. A recording carries the whole model description in its header, so a
//  log can be replayed, plotted and re-rendered without the original scene file.
//
//  Layout
//    magic      6 bytes  "KNLOG\0"
//    version    uint32   little endian
//    headerLen  uint64
//    header     JSON (UTF-8)
//    frames     repeated: "FRAM" uint32, time float64, payloadLen uint32, payload
//

import Foundation

public struct LogGeomDescription: Codable, Sendable {
    public var name: String
    public var kind: Int
    public var size: [Double]
    public var color: [Double]
    public var metallic: Double
    public var roughness: Double
    public var articulation: Int
    public var link: Int
    public var visible: Bool
}

public struct LogHeader: Codable, Sendable {
    public var version: Int = 1
    public var createdAt: Date = Date()
    public var title: String = "Kinetic recording"
    public var timestep: Double = 1.0 / 500.0
    public var gravity: [Double] = [0, 0, -9.81]
    public var coordinateCount: Int = 0
    public var dofCount: Int = 0
    public var actuatorCount: Int = 0
    public var sensorDataCount: Int = 0
    public var linkCount: Int = 0
    public var geoms: [LogGeomDescription] = []
    public var linkNames: [String] = []
    public var actuatorNames: [String] = []
    public var sensorNames: [String] = []
    public var sensorDimensions: [Int] = []
    public var engineVersion: String = World.versionString

    public init() {}
}

public struct LogFrame: Sendable {
    public var time: Double
    public var positions: [Double]
    public var velocities: [Double]
    public var control: [Double]
    public var sensors: [Double]
    public var linkPoses: [Float]   // 7 per link: xyz + wxyz
    public var contacts: [Contact]
    public var stepMilliseconds: Double
}

public enum LogError: Error, CustomStringConvertible {
    case badMagic
    case truncated
    case unsupportedVersion(Int)
    case cannotOpen(URL)

    public var description: String {
        switch self {
        case .badMagic: return "not a Kinetic recording"
        case .truncated: return "recording is truncated"
        case .unsupportedVersion(let v): return "unsupported recording version \(v)"
        case .cannotOpen(let u): return "cannot open \(u.path)"
        }
    }
}

private let kLogMagic: [UInt8] = Array("KNLOG\0".utf8)
private let kFrameMagic: UInt32 = 0x4D_41_52_46  // "FRAM"

// MARK: - Binary helpers

private struct ByteWriter {
    var data = Data()
    mutating func append<T>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    mutating func append(_ values: [Double]) {
        values.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
    }
    mutating func append(_ values: [Float]) {
        values.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
    }
    mutating func append(bytes: [UInt8]) { data.append(contentsOf: bytes) }
}

private struct ByteReader {
    let data: Data
    var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func read<T>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw LogError.truncated }
        let value = data.withUnsafeBytes { raw -> T in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += size
        return value
    }

    mutating func readDoubles(_ count: Int) throws -> [Double] {
        let size = count * MemoryLayout<Double>.size
        guard remaining >= size else { throw LogError.truncated }
        var out = [Double](repeating: 0, count: count)
        if count > 0 {
            out.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst.bindMemory(to: UInt8.self),
                               from: offset..<(offset + size))
            }
        }
        offset += size
        return out
    }

    mutating func readFloats(_ count: Int) throws -> [Float] {
        let size = count * MemoryLayout<Float>.size
        guard remaining >= size else { throw LogError.truncated }
        var out = [Float](repeating: 0, count: count)
        if count > 0 {
            out.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst.bindMemory(to: UInt8.self),
                               from: offset..<(offset + size))
            }
        }
        offset += size
        return out
    }
}

// MARK: - Recorder

public final class LogRecorder {
    private let handle: FileHandle
    private(set) public var header: LogHeader
    private(set) public var frameCount = 0
    private var buffer = Data()
    private let flushThreshold = 1 << 20

    public init(url: URL, world: World, title: String = "Kinetic recording") throws {
        var header = LogHeader()
        header.title = title
        header.timestep = world.options.timestep
        header.gravity = [world.options.gravity.x, world.options.gravity.y, world.options.gravity.z]
        header.coordinateCount = world.coordinateCount
        header.dofCount = world.dofCount
        header.actuatorCount = world.actuatorCount
        header.sensorDataCount = world.sensorDataCount
        header.linkCount = world.linkCount
        header.sensorNames = world.sensorNames
        header.actuatorNames = world.actuatorNames
        header.sensorDimensions = world.sensorKinds.map(\.dimension)
        for a in 0..<world.articulationCount {
            for l in 0..<world.linkCount(articulation: a) {
                header.linkNames.append("\(world.name(articulation: a)).\(world.name(articulation: a, link: l))")
            }
        }
        header.geoms = world.geomInfo.map { info in
            let size = info.shape.cSize
            return LogGeomDescription(
                name: info.name, kind: Int(info.shape.cType),
                size: [size.x, size.y, size.z],
                color: [info.appearance.color.x, info.appearance.color.y,
                        info.appearance.color.z, info.appearance.color.w],
                metallic: info.appearance.metallic, roughness: info.appearance.roughness,
                articulation: info.articulation, link: info.link, visible: info.visible)
        }
        self.header = header

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { throw LogError.cannotOpen(url) }
        self.handle = handle

        var writer = ByteWriter()
        writer.append(bytes: kLogMagic)
        writer.append(UInt32(1))
        let headerData = try JSONEncoder().encode(header)
        writer.append(UInt64(headerData.count))
        writer.data.append(headerData)
        try handle.write(contentsOf: writer.data)
    }

    public func record(_ world: World) {
        var writer = ByteWriter()
        var payload = ByteWriter()
        payload.append(Array(world.positions))
        payload.append(Array(world.velocities))
        payload.append(Array(world.control))
        payload.append(Array(world.sensorReadings))

        let poses = world.linkPoses()
        var flat = [Float]()
        flat.reserveCapacity(poses.count * 7)
        for p in poses {
            flat.append(contentsOf: [Float(p.position.x), Float(p.position.y), Float(p.position.z),
                                     Float(p.orientation.w), Float(p.orientation.x),
                                     Float(p.orientation.y), Float(p.orientation.z)])
        }
        payload.append(flat)

        let contacts = world.contacts()
        payload.append(UInt32(contacts.count))
        for c in contacts {
            payload.append([c.point.x, c.point.y, c.point.z,
                            c.normal.x, c.normal.y, c.normal.z,
                            c.force.x, c.force.y, c.force.z, c.depth])
            payload.append(Int32(c.geomA))
            payload.append(Int32(c.geomB))
        }
        payload.append(world.profile.total)

        writer.append(kFrameMagic)
        writer.append(world.time)
        writer.append(UInt32(payload.data.count))
        writer.data.append(payload.data)

        buffer.append(writer.data)
        frameCount += 1
        if buffer.count >= flushThreshold { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    public func finish() {
        flush()
        try? handle.close()
    }

    deinit { finish() }
}

// MARK: - Player

public final class LogPlayer {
    public let header: LogHeader
    private let data: Data
    private var frameOffsets: [Int] = []
    private var frameTimes: [Double] = []

    public var frameCount: Int { frameOffsets.count }
    public var duration: Double { frameTimes.last ?? 0 }
    public var startTime: Double { frameTimes.first ?? 0 }
    public var times: [Double] { frameTimes }

    public init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw LogError.cannotOpen(url)
        }
        self.data = data

        guard data.count > kLogMagic.count + 12 else { throw LogError.truncated }
        for (i, byte) in kLogMagic.enumerated() where data[data.startIndex + i] != byte {
            throw LogError.badMagic
        }
        var reader = ByteReader(data, offset: kLogMagic.count)
        let version: UInt32 = try reader.read(UInt32.self)
        guard version == 1 else { throw LogError.unsupportedVersion(Int(version)) }
        let headerLength: UInt64 = try reader.read(UInt64.self)
        let headerRange = reader.offset..<(reader.offset + Int(headerLength))
        guard headerRange.upperBound <= data.count else { throw LogError.truncated }
        header = try JSONDecoder().decode(LogHeader.self, from: data.subdata(in: headerRange))
        reader.offset = headerRange.upperBound

        // Index the frames.
        while reader.remaining >= 16 {
            let start = reader.offset
            let magic: UInt32 = try reader.read(UInt32.self)
            guard magic == kFrameMagic else { break }
            let time: Double = try reader.read(Double.self)
            let payloadLength: UInt32 = try reader.read(UInt32.self)
            guard reader.remaining >= Int(payloadLength) else { break }
            frameOffsets.append(start)
            frameTimes.append(time)
            reader.offset += Int(payloadLength)
        }
    }

    public func frame(at index: Int) throws -> LogFrame {
        guard index >= 0, index < frameOffsets.count else { throw LogError.truncated }
        var reader = ByteReader(data, offset: frameOffsets[index])
        _ = try reader.read(UInt32.self)
        let time: Double = try reader.read(Double.self)
        _ = try reader.read(UInt32.self)

        let positions = try reader.readDoubles(header.coordinateCount)
        let velocities = try reader.readDoubles(header.dofCount)
        let control = try reader.readDoubles(header.actuatorCount)
        let sensors = try reader.readDoubles(header.sensorDataCount)
        let poses = try reader.readFloats(header.linkCount * 7)

        let contactCount: UInt32 = try reader.read(UInt32.self)
        var contacts: [Contact] = []
        contacts.reserveCapacity(Int(contactCount))
        for _ in 0..<Int(contactCount) {
            let v = try reader.readDoubles(10)
            let a: Int32 = try reader.read(Int32.self)
            let b: Int32 = try reader.read(Int32.self)
            contacts.append(Contact(point: Vec3(v[0], v[1], v[2]),
                                    normal: Vec3(v[3], v[4], v[5]),
                                    force: Vec3(v[6], v[7], v[8]),
                                    depth: v[9], geomA: Int(a), geomB: Int(b)))
        }
        let stepMs = (try? reader.read(Double.self)) ?? 0

        return LogFrame(time: time, positions: positions, velocities: velocities, control: control,
                        sensors: sensors, linkPoses: poses, contacts: contacts,
                        stepMilliseconds: stepMs)
    }

    /// Index of the last frame at or before `time`.
    public func index(forTime time: Double) -> Int {
        guard !frameTimes.isEmpty else { return 0 }
        var low = 0, high = frameTimes.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if frameTimes[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Extracts one scalar channel across the whole recording, for plotting.
    public func channel(_ channel: LogChannel) throws -> (times: [Double], values: [Double]) {
        var values = [Double](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let f = try frame(at: i)
            values[i] = channel.extract(f)
        }
        return (frameTimes, values)
    }
}

/// Addresses one scalar time series inside a recording.
public struct LogChannel: Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case position, velocity, control, sensor, stepTime, contactCount, contactForce
    }

    public var source: Source
    public var index: Int
    public var label: String

    public init(source: Source, index: Int, label: String) {
        self.source = source
        self.index = index
        self.label = label
    }

    public func extract(_ frame: LogFrame) -> Double {
        switch source {
        case .position: return frame.positions.indices.contains(index) ? frame.positions[index] : 0
        case .velocity: return frame.velocities.indices.contains(index) ? frame.velocities[index] : 0
        case .control: return frame.control.indices.contains(index) ? frame.control[index] : 0
        case .sensor: return frame.sensors.indices.contains(index) ? frame.sensors[index] : 0
        case .stepTime: return frame.stepMilliseconds
        case .contactCount: return Double(frame.contacts.count)
        case .contactForce:
            return frame.contacts.reduce(0) { $0 + abs($1.normalForce) }
        }
    }
}

extension LogPlayer {
    /// Every channel a recording exposes, ready to drop into a plot picker.
    public var availableChannels: [LogChannel] {
        var channels: [LogChannel] = []
        for i in 0..<header.dofCount {
            channels.append(LogChannel(source: .velocity, index: i, label: "qvel[\(i)]"))
        }
        for i in 0..<header.coordinateCount {
            channels.append(LogChannel(source: .position, index: i, label: "qpos[\(i)]"))
        }
        for i in 0..<header.actuatorCount {
            let name = header.actuatorNames.indices.contains(i) ? header.actuatorNames[i] : "u[\(i)]"
            channels.append(LogChannel(source: .control, index: i, label: name))
        }
        var sensorIndex = 0
        for (i, name) in header.sensorNames.enumerated() {
            let dim = header.sensorDimensions.indices.contains(i) ? header.sensorDimensions[i] : 1
            for k in 0..<dim {
                let suffix = dim == 1 ? "" : ".\(["x", "y", "z", "w"][min(k, 3)])"
                channels.append(LogChannel(source: .sensor, index: sensorIndex,
                                           label: "\(name)\(suffix)"))
                sensorIndex += 1
            }
        }
        channels.append(LogChannel(source: .stepTime, index: 0, label: "step time (ms)"))
        channels.append(LogChannel(source: .contactCount, index: 0, label: "contacts"))
        channels.append(LogChannel(source: .contactForce, index: 0, label: "total normal force (N)"))
        return channels
    }

    public func exportCSV(channels: [LogChannel], to url: URL) throws {
        var text = "time," + channels.map(\.label).joined(separator: ",") + "\n"
        for i in 0..<frameCount {
            let f = try frame(at: i)
            let row = channels.map { String(format: "%.9g", $0.extract(f)) }.joined(separator: ",")
            text += String(format: "%.9g", f.time) + "," + row + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
