//
//  RecordingTests.swift
//  KineticTests
//

import Foundation
import Testing

@testable import Kinetic
@testable import KineticBridge

@Suite("Recording format")
struct RecordingTests {

    private func temporaryURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kinetic-test-\(UUID().uuidString).\(ext)")
    }

    @Test("A recording round-trips state, contacts and metadata")
    func roundTrip() throws {
        let url = temporaryURL("kinlog")
        defer { try? FileManager.default.removeItem(at: url) }

        let world = SceneLibrary.boxStack(count: 3)
        let recorder = try LogRecorder(url: url, world: world, title: "stack test")
        var expectedPositions: [[Double]] = []
        for _ in 0..<120 {
            world.step()
            recorder.record(world)
            expectedPositions.append(Array(world.positions))
        }
        recorder.finish()

        let player = try LogPlayer(url: url)
        #expect(player.header.title == "stack test")
        #expect(player.frameCount == 120)
        #expect(player.header.coordinateCount == world.coordinateCount)
        #expect(player.header.geoms.count == world.geomCount)
        #expect(player.header.linkNames.count == world.linkCount)

        let first = try player.frame(at: 0)
        #expect(first.positions == expectedPositions[0])
        #expect(first.linkPoses.count == world.linkCount * 7)

        let last = try player.frame(at: 119)
        #expect(last.positions == expectedPositions[119])
        #expect(abs(last.time - world.time) < 1e-9)
        #expect(!last.contacts.isEmpty)
    }

    @Test("Seeking by time lands on the right frame")
    func seeking() throws {
        let url = temporaryURL("kinlog")
        defer { try? FileManager.default.removeItem(at: url) }

        let world = SceneLibrary.cartPole()
        let recorder = try LogRecorder(url: url, world: world)
        for _ in 0..<200 {
            world.step()
            recorder.record(world)
        }
        recorder.finish()

        let player = try LogPlayer(url: url)
        let midpoint = player.duration / 2
        let index = player.index(forTime: midpoint)
        let frame = try player.frame(at: index)
        #expect(frame.time <= midpoint + 1e-9)
        if index + 1 < player.frameCount {
            #expect(try player.frame(at: index + 1).time > midpoint)
        }
    }

    @Test("Channels extract and export")
    func channels() throws {
        let url = temporaryURL("kinlog")
        let csv = temporaryURL("csv")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: csv)
        }

        let world = SceneLibrary.cartPole()
        let recorder = try LogRecorder(url: url, world: world)
        for _ in 0..<100 {
            world.step()
            recorder.record(world)
        }
        recorder.finish()

        let player = try LogPlayer(url: url)
        let channels = player.availableChannels
        #expect(channels.contains { $0.label == "step time (ms)" })

        let velocity = try #require(channels.first { $0.source == .velocity })
        let (times, values) = try player.channel(velocity)
        #expect(times.count == 100)
        #expect(values.count == 100)
        #expect(values.contains { $0 != 0 })

        try player.exportCSV(channels: Array(channels.prefix(6)), to: csv)
        let text = try String(contentsOf: csv, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 101)
        #expect(lines[0].hasPrefix("time,"))
    }

    @Test("A file that is not a recording is rejected")
    func notARecording() throws {
        let url = temporaryURL("kinlog")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a kinetic log, just some bytes that are long enough".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LogPlayer(url: url) }
    }
}

@Suite("Telemetry transport")
struct WebSocketFramingTests {

    @Test("Frames round-trip across every length class")
    func framing() {
        for length in [0, 5, 125, 126, 200, 65535, 65536, 70000] {
            let payload = Data((0..<length).map { UInt8($0 % 251) })
            let frame = WebSocketServer.encodeFrame(opcode: 0x2, payload: payload)
            let decoded = WebSocketServer.decodeFrame(from: frame)
            #expect(decoded != nil)
            #expect(decoded?.opcode == 0x2)
            #expect(decoded?.payload == payload)
            #expect(decoded?.consumed == frame.count)
        }
    }

    @Test("A partial frame decodes to nil rather than consuming bytes")
    func partialFrame() {
        let payload = Data(repeating: 7, count: 400)
        let frame = WebSocketServer.encodeFrame(opcode: 0x1, payload: payload)
        #expect(WebSocketServer.decodeFrame(from: frame.prefix(10)) == nil)
        #expect(WebSocketServer.decodeFrame(from: frame) != nil)
    }

    @Test("Masked client frames are unmasked correctly")
    func maskedFrame() {
        let payload = Data("hello kinetic".utf8)
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        var frame = Data()
        frame.append(0x81)
        frame.append(0x80 | UInt8(payload.count))
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }

        let decoded = WebSocketServer.decodeFrame(from: frame)
        #expect(decoded?.payload == payload)
        #expect(decoded?.opcode == 0x1)
    }
}
