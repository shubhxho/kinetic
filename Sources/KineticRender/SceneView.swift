//
//  SceneView.swift
//  KineticRender
//
//  The AppKit view that owns the render loop plus a SwiftUI wrapper. The
//  simulation is stepped from the display callback with a fixed-step
//  accumulator, so physics, picking and rendering all observe the same state on
//  the same thread — no snapshot copies and no data races.
//

import AppKit
import Combine
import Kinetic
import MetalKit
import SwiftUI
import simd

public struct ViewportStats: Sendable {
    public var simulationTime: Double = 0
    public var realtimeFactor: Double = 1
    public var stepMilliseconds: Double = 0
    public var drawMilliseconds: Double = 0
    public var contactCount: Int = 0
    public var constraintCount: Int = 0
    public var stepsPerFrame: Int = 0
    public var instanceCount: Int = 0
    public var frameRate: Double = 0
    public var kineticEnergy: Double = 0
    public var potentialEnergy: Double = 0
}

public protocol ViewportDelegate: AnyObject {
    func viewport(_ view: KineticView, didUpdate stats: ViewportStats)
    func viewport(_ view: KineticView, didSelectGeom geom: Int?)
    func viewportWillStep(_ view: KineticView)
}

public final class KineticView: MTKView {
    public var world: World? {
        didSet {
            trailReset()
            if let world { camera.frame(min: SIMD3(-1, -1, 0), max: SIMD3(1, 1, 1)); _ = world }
        }
    }
    public var settings = RenderSettings()
    public var camera = OrbitCamera()
    public weak var viewportDelegate: ViewportDelegate?

    public var isPlaying = false
    /// Multiplier on wall-clock time. 1.0 tracks realtime; 0 steps only on demand.
    public var timeScale: Double = 1.0
    /// When false the simulation advances exactly one step per frame.
    public var followsRealtime = true
    public var maxStepsPerFrame = 12

    private var renderer: Renderer?
    private var accumulator: Double = 0
    private var lastFrameTimestamp = CACurrentMediaTime()
    private var frameRateEstimate: Double = 60
    private var pendingSingleStep = false
    private var dragOrigin = CGPoint.zero

    public init(renderer: Renderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .invalid
        framebufferOnly = false
        preferredFramesPerSecond = 120
        isPaused = false
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
        allowedTouchTypes = [.indirect]
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    private func trailReset() {
        accumulator = 0
    }

    public func requestSingleStep() {
        pendingSingleStep = true
    }

    public func frameScene() {
        guard let world else { return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for pose in world.linkPoses() {
            let p = SIMD3<Float>(Float(pose.position.x), Float(pose.position.y),
                                 Float(pose.position.z))
            lo = simd_min(lo, p - SIMD3<Float>(repeating: 0.25))
            hi = simd_max(hi, p + SIMD3<Float>(repeating: 0.25))
        }
        if lo.x > hi.x {
            lo = SIMD3<Float>(-1, -1, 0)
            hi = SIMD3<Float>(1, 1, 1)
        }
        camera.frame(min: lo, max: hi)
    }

    // MARK: Input

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            camera.pan(deltaX: Float(event.scrollingDeltaX), deltaY: Float(event.scrollingDeltaY))
        } else {
            camera.zoom(Float(event.scrollingDeltaY))
        }
    }

    public override func magnify(with event: NSEvent) {
        camera.zoom(Float(event.magnification) * 12)
    }

    public override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
    }

    public override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            camera.pan(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
        } else {
            camera.orbit(deltaX: Float(event.deltaX) * 0.006,
                         deltaY: Float(event.deltaY) * 0.006)
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        camera.pan(deltaX: Float(event.deltaX), deltaY: Float(event.deltaY))
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) < 3 {
            select(at: point)
        }
    }

    private func select(at point: CGPoint) {
        guard let world else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               Float(point.y / size.height) * 2 - 1)
        let aspect = Float(size.width / size.height)
        let inverse = (camera.projectionMatrix(aspect: aspect) * camera.viewMatrix).inverse
        let nearPoint = inverse * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
        let farPoint = inverse * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        let origin = nearPoint.xyz / nearPoint.w
        let target = farPoint.xyz / farPoint.w
        let direction = simd_normalize(target - origin)

        let hit = world.raycast(origin: Vec3(Double(origin.x), Double(origin.y), Double(origin.z)),
                                direction: Vec3(Double(direction.x), Double(direction.y),
                                                Double(direction.z)),
                                maxDistance: 500)
        if let hit {
            settings.selection = [hit.geom]
            viewportDelegate?.viewport(self, didSelectGeom: hit.geom)
        } else {
            settings.selection = []
            viewportDelegate?.viewport(self, didSelectGeom: nil)
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ": isPlaying.toggle()
        case "f": frameScene()
        case ".": requestSingleStep()
        case "g": settings.showGrid.toggle()
        case "c": settings.showContacts.toggle()
        case "k": settings.showCollisionGeometry.toggle()
        case "w": settings.wireframe.toggle()
        case "t": settings.showTrails.toggle()
        default: super.keyDown(with: event)
        }
    }
}

extension KineticView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let delta = min(now - lastFrameTimestamp, 0.25)
        lastFrameTimestamp = now
        frameRateEstimate = frameRateEstimate * 0.9 + (1.0 / max(delta, 1e-4)) * 0.1

        guard let world, let renderer else { return }

        var steps = 0
        let timestep = world.options.timestep
        if pendingSingleStep {
            viewportDelegate?.viewportWillStep(self)
            world.step()
            steps = 1
            pendingSingleStep = false
        } else if isPlaying {
            if followsRealtime {
                accumulator += delta * timeScale
                while accumulator >= timestep, steps < maxStepsPerFrame {
                    viewportDelegate?.viewportWillStep(self)
                    world.step()
                    accumulator -= timestep
                    steps += 1
                }
                if steps == maxStepsPerFrame { accumulator = 0 }  // give up catching up
            } else {
                viewportDelegate?.viewportWillStep(self)
                world.step()
                steps = 1
            }
        }

        renderer.draw(world: world, settings: settings, camera: camera, in: view)

        let profile = world.profile
        var stats = ViewportStats()
        stats.simulationTime = world.time
        stats.stepMilliseconds = profile.total
        stats.drawMilliseconds = renderer.lastDrawMilliseconds
        stats.contactCount = profile.contactCount
        stats.constraintCount = profile.constraintCount
        stats.stepsPerFrame = steps
        stats.instanceCount = renderer.lastInstanceCount
        stats.frameRate = frameRateEstimate
        stats.realtimeFactor = steps > 0 ? Double(steps) * timestep / max(delta, 1e-6) : 0
        stats.kineticEnergy = world.kineticEnergy
        stats.potentialEnergy = world.potentialEnergy
        viewportDelegate?.viewport(self, didUpdate: stats)
    }
}

// MARK: - SwiftUI wrapper

public struct SimulationViewport: NSViewRepresentable {
    private let world: World
    private let renderer: Renderer
    @Binding private var settings: RenderSettings
    @Binding private var isPlaying: Bool
    @Binding private var timeScale: Double
    private let onStats: (ViewportStats) -> Void
    private let onSelect: (Int?) -> Void
    private let onWillStep: () -> Void
    private let commands: ViewportCommands

    public init(world: World, renderer: Renderer, settings: Binding<RenderSettings>,
                isPlaying: Binding<Bool>, timeScale: Binding<Double>,
                commands: ViewportCommands,
                onStats: @escaping (ViewportStats) -> Void = { _ in },
                onSelect: @escaping (Int?) -> Void = { _ in },
                onWillStep: @escaping () -> Void = {}) {
        self.world = world
        self.renderer = renderer
        self._settings = settings
        self._isPlaying = isPlaying
        self._timeScale = timeScale
        self.commands = commands
        self.onStats = onStats
        self.onSelect = onSelect
        self.onWillStep = onWillStep
    }

    public func makeNSView(context: Context) -> KineticView {
        let view = KineticView(renderer: renderer)
        view.world = world
        view.settings = settings
        view.viewportDelegate = context.coordinator
        context.coordinator.view = view
        commands.attach(view)
        DispatchQueue.main.async { view.frameScene() }
        return view
    }

    public func updateNSView(_ view: KineticView, context: Context) {
        if view.world !== world {
            view.world = world
            DispatchQueue.main.async { view.frameScene() }
        }
        view.settings = settings
        view.isPlaying = isPlaying
        view.timeScale = timeScale
        context.coordinator.parent = self
    }

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public final class Coordinator: ViewportDelegate {
        var parent: SimulationViewport
        weak var view: KineticView?

        init(parent: SimulationViewport) { self.parent = parent }

        public func viewport(_ view: KineticView, didUpdate stats: ViewportStats) {
            parent.onStats(stats)
        }

        public func viewport(_ view: KineticView, didSelectGeom geom: Int?) {
            parent.onSelect(geom)
        }

        public func viewportWillStep(_ view: KineticView) {
            parent.onWillStep()
        }
    }
}

/// Lets SwiftUI trigger imperative viewport actions without owning the view.
public final class ViewportCommands: ObservableObject {
    private weak var view: KineticView?

    public init() {}

    func attach(_ view: KineticView) { self.view = view }

    public func frameScene() { view?.frameScene() }
    public func singleStep() { view?.requestSingleStep() }
    public func setCamera(_ preset: CameraPreset) {
        guard let view else { return }
        switch preset {
        case .front: view.camera.azimuth = -.pi / 2; view.camera.elevation = 0.05
        case .side: view.camera.azimuth = 0; view.camera.elevation = 0.05
        case .top: view.camera.azimuth = -.pi / 2; view.camera.elevation = 1.5
        case .isometric: view.camera.azimuth = -0.9; view.camera.elevation = 0.42
        }
    }
    public var camera: OrbitCamera? { view?.camera }
}

public enum CameraPreset: String, CaseIterable, Sendable {
    case isometric, front, side, top
}
