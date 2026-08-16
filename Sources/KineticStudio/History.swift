//
//  History.swift
//  Kinetic Studio
//
//  A rolling window of past simulation states. Every step is snapshotted, so the
//  timeline can be dragged backwards through what already happened without
//  re-running anything — the thing you actually want when a controller misbehaves
//  for three frames and you need to see exactly what the contacts did.
//
//  A state is (nq + nv + 1) doubles. At 500 Hz with a 30-second window and a
//  60-dof scene that is about 30 MB, so the window is expressed in seconds and
//  the buffer sizes itself from the model.
//

import Foundation
import Kinetic

struct HistoryFrame {
    var time: Double
    var contactCount: Int
    var stepMilliseconds: Double
    var totalEnergy: Double
    var solverResidual: Double
    var solverIterations: Int
    var constraintCount: Int
}

final class StateHistory {
    private(set) var frames: [HistoryFrame] = []
    private var states: [[Double]] = []
    private var head = 0
    private var filled = false

    /// How much wall-clock history to keep, in seconds of simulated time.
    var windowSeconds: Double = 20 {
        didSet { resize() }
    }
    private(set) var capacity = 0
    private var timestep: Double = 1.0 / 500.0

    var count: Int { filled ? capacity : head }
    var isEmpty: Bool { count == 0 }

    var startTime: Double { frames.isEmpty ? 0 : frame(at: 0).time }
    var endTime: Double { count == 0 ? 0 : frame(at: count - 1).time }

    func configure(for world: World) {
        timestep = max(world.options.timestep, 1e-6)
        resize()
        clear()
    }

    private func resize() {
        capacity = max(64, Int(windowSeconds / timestep))
        states = Array(repeating: [], count: capacity)
        frames = Array(repeating: HistoryFrame(time: 0, contactCount: 0, stepMilliseconds: 0,
                                               totalEnergy: 0, solverResidual: 0,
                                               solverIterations: 0, constraintCount: 0),
                       count: capacity)
        head = 0
        filled = false
    }

    func clear() {
        head = 0
        filled = false
    }

    func record(_ world: World) {
        if capacity == 0 { configure(for: world) }
        states[head] = world.saveState()
        let profile = world.profile
        frames[head] = HistoryFrame(time: world.time,
                                    contactCount: profile.contactCount,
                                    stepMilliseconds: profile.total,
                                    totalEnergy: world.kineticEnergy + world.potentialEnergy,
                                    solverResidual: profile.solverResidual,
                                    solverIterations: profile.solverIterations,
                                    constraintCount: profile.constraintCount)
        head = (head + 1) % capacity
        if head == 0 { filled = true }
    }

    /// Chronological index: 0 is the oldest frame still held.
    func frame(at index: Int) -> HistoryFrame {
        frames[storageIndex(index)]
    }

    func restore(_ index: Int, into world: World) {
        let state = states[storageIndex(index)]
        guard !state.isEmpty else { return }
        world.loadState(state)
    }

    private func storageIndex(_ index: Int) -> Int {
        let clamped = max(0, min(index, count - 1))
        guard filled else { return clamped }
        return (head + clamped) % capacity
    }

    /// Index of the last frame at or before `time`.
    func index(forTime time: Double) -> Int {
        guard count > 0 else { return 0 }
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if frame(at: mid).time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Downsampled contact counts for the timeline track.
    func contactTrack(buckets: Int) -> [Double] {
        guard count > 1, buckets > 0 else { return [] }
        var out = [Double](repeating: 0, count: buckets)
        let stride = Double(count) / Double(buckets)
        for bucket in 0..<buckets {
            let lo = Int(Double(bucket) * stride)
            let hi = max(lo + 1, Int(Double(bucket + 1) * stride))
            var peak = 0.0
            for i in lo..<min(hi, count) {
                peak = max(peak, Double(frame(at: i).contactCount))
            }
            out[bucket] = peak
        }
        return out
    }

    var approximateBytes: Int {
        guard let sample = states.first(where: { !$0.isEmpty }) else { return 0 }
        return sample.count * MemoryLayout<Double>.size * count
    }
}
