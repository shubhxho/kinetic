//
//  Renderer.swift
//  KineticRender
//
//  Metal forward renderer for a Kinetic world: instanced PBR geometry, a
//  directional shadow map, an analytic ground grid, debug overlays for contacts
//  and frames, and an ACES resolve pass.
//

import Foundation
import Kinetic
import Metal
import MetalKit
import simd

// MARK: - GPU-facing layouts (must match kinetic.metal)

struct FrameUniforms {
    var viewProjection = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var lightViewProjection = matrix_identity_float4x4
    var cameraPosition = SIMD4<Float>(0, 0, 0, 1)
    var lightDirection = SIMD4<Float>(0, 0, 1, 3)
    var lightColor = SIMD4<Float>(1, 1, 1, 1)
    var skyColor = SIMD4<Float>(0.30, 0.34, 0.42, 1)
    var groundColor = SIMD4<Float>(0.05, 0.05, 0.06, 1)
    var params = SIMD4<Float>(1, 0, 1.0 / 2048.0, 0.35)
    var gridParams = SIMD4<Float>(0.25, 4, 46, 1)
    var gridColor = SIMD4<Float>(0.16, 0.16, 0.18, 1)
}

struct InstanceData {
    var model = matrix_identity_float4x4
    var normalMatrix = matrix_identity_float4x4
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var params = SIMD4<Float>(0, 0.5, 0, 0)
}

struct LineVertex {
    var position = SIMD4<Float>(0, 0, 0, 1)
    var color = SIMD4<Float>(1, 1, 1, 1)
}

// MARK: - Settings

public struct RenderTheme: Sendable, Equatable {
    public var background: SIMD4<Float>
    public var gridColor: SIMD4<Float>
    public var skyAmbient: SIMD4<Float>
    public var groundAmbient: SIMD4<Float>
    public var ambientIntensity: Float
    public var lightIntensity: Float
    public var exposure: Float

    public static let dark = RenderTheme(
        background: SIMD4<Float>(0.0, 0.0, 0.0, 1),
        gridColor: SIMD4<Float>(0.19, 0.19, 0.21, 1),
        skyAmbient: SIMD4<Float>(0.26, 0.30, 0.40, 1),
        groundAmbient: SIMD4<Float>(0.03, 0.03, 0.04, 1),
        ambientIntensity: 0.45,
        lightIntensity: 3.0,
        exposure: 1.05)

    public static let light = RenderTheme(
        background: SIMD4<Float>(0.976, 0.976, 0.980, 1),
        gridColor: SIMD4<Float>(0.78, 0.78, 0.80, 1),
        skyAmbient: SIMD4<Float>(0.88, 0.90, 0.96, 1),
        groundAmbient: SIMD4<Float>(0.55, 0.55, 0.58, 1),
        ambientIntensity: 0.85,
        lightIntensity: 2.4,
        exposure: 1.0)
}

public struct RenderSettings: Sendable {
    public var showVisualGeometry = true
    public var showCollisionGeometry = false
    public var showGrid = true
    public var showContacts = true
    public var showContactForces = true
    public var showLinkFrames = false
    public var showCenterOfMass = false
    public var showTrails = false
    public var wireframe = false
    public var contactForceScale: Float = 0.006
    public var theme: RenderTheme = .dark
    public var selection: Set<Int> = []
    public var lightAzimuth: Float = -0.7
    public var lightElevation: Float = 0.95

    public init() {}
}

// MARK: - Renderer

public final class Renderer {
    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let meshes: MeshLibrary

    private var scenePipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var gridPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var overlayPipeline: MTLRenderPipelineState!
    private var postPipeline: MTLRenderPipelineState!

    private var sceneDepthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!
    private var gridDepthState: MTLDepthStencilState!
    private var shadowDepthState: MTLDepthStencilState!

    private var shadowMap: MTLTexture!
    private var colorTarget: MTLTexture?
    private var depthTarget: MTLTexture?
    private var resolveTarget: MTLTexture?
    private var targetSize = CGSize.zero

    private var shadowSampler: MTLSamplerState!
    private var linearSampler: MTLSamplerState!

    private let sampleCount: Int
    private let colorFormat: MTLPixelFormat = .rgba16Float

    private var instanceBuffers: [MeshKey: MTLBuffer] = [:]
    private var lineBuffer: MTLBuffer?
    private var overlayInstanceBuffer: MTLBuffer?
    private var trails: [Int: [SIMD3<Float>]] = [:]

    public private(set) var lastDrawMilliseconds: Double = 0
    public private(set) var lastInstanceCount: Int = 0
    public private(set) var lastDrawCallCount: Int = 0

    public init?(device: MTLDevice? = nil, sampleCount: Int = 4) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.sampleCount = device.supportsTextureSampleCount(sampleCount) ? sampleCount : 1
        self.meshes = MeshLibrary(device: device)

        guard let source = Renderer.loadShaderSource(),
              let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        self.library = library

        do {
            try buildPipelines()
        } catch {
            NSLog("Kinetic renderer: pipeline creation failed — \(error)")
            return nil
        }
        buildResources()
    }

    private static func loadShaderSource() -> String? {
        if let url = Bundle.module.url(forResource: "kinetic", withExtension: "metal",
                                       subdirectory: "Shaders"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        if let url = Bundle.module.url(forResource: "kinetic", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        return nil
    }

    private func vertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float3
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].format = .float3
        descriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        descriptor.attributes[1].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<RenderVertex>.stride
        return descriptor
    }

    private func buildPipelines() throws {
        let vertexDescriptor = self.vertexDescriptor()

        func makePipeline(_ label: String, _ vertex: String, _ fragment: String?,
                          blending: Bool = false, useVertexDescriptor: Bool = true,
                          depthOnly: Bool = false, samples: Int? = nil) throws
            -> MTLRenderPipelineState
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            if let fragment { descriptor.fragmentFunction = library.makeFunction(name: fragment) }
            if useVertexDescriptor { descriptor.vertexDescriptor = vertexDescriptor }
            descriptor.rasterSampleCount = samples ?? sampleCount
            if depthOnly {
                descriptor.depthAttachmentPixelFormat = .depth32Float
            } else {
                descriptor.colorAttachments[0].pixelFormat = colorFormat
                descriptor.depthAttachmentPixelFormat = .depth32Float
                if blending {
                    let attachment = descriptor.colorAttachments[0]!
                    attachment.isBlendingEnabled = true
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .sourceAlpha
                    attachment.sourceAlphaBlendFactor = .sourceAlpha
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        scenePipeline = try makePipeline("scene", "scene_vertex", "scene_fragment")
        overlayPipeline = try makePipeline("overlay", "overlay_vertex", "overlay_fragment",
                                           blending: true)
        gridPipeline = try makePipeline("grid", "grid_vertex", "grid_fragment", blending: true,
                                        useVertexDescriptor: false)
        linePipeline = try makePipeline("line", "line_vertex", "line_fragment", blending: true,
                                        useVertexDescriptor: false)

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.label = "shadow"
        shadowDescriptor.vertexFunction = library.makeFunction(name: "shadow_vertex")
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        shadowDescriptor.rasterSampleCount = 1
        shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)

        let postDescriptor = MTLRenderPipelineDescriptor()
        postDescriptor.label = "post"
        postDescriptor.vertexFunction = library.makeFunction(name: "post_vertex")
        postDescriptor.fragmentFunction = library.makeFunction(name: "post_fragment")
        postDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        postDescriptor.rasterSampleCount = 1
        postPipeline = try device.makeRenderPipelineState(descriptor: postDescriptor)
    }

    private func buildResources() {
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        sceneDepthState = device.makeDepthStencilState(descriptor: depthDescriptor)
        shadowDepthState = sceneDepthState

        let overlayDescriptor = MTLDepthStencilDescriptor()
        overlayDescriptor.depthCompareFunction = .lessEqual
        overlayDescriptor.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: overlayDescriptor)
        gridDepthState = overlayDepthState

        let shadowDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        shadowDescriptor.usage = [.renderTarget, .shaderRead]
        shadowDescriptor.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowDescriptor)
        shadowMap.label = "kinetic.shadowMap"

        let shadowSamplerDescriptor = MTLSamplerDescriptor()
        shadowSamplerDescriptor.minFilter = .linear
        shadowSamplerDescriptor.magFilter = .linear
        shadowSamplerDescriptor.sAddressMode = .clampToEdge
        shadowSamplerDescriptor.tAddressMode = .clampToEdge
        shadowSampler = device.makeSamplerState(descriptor: shadowSamplerDescriptor)

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        linearDescriptor.sAddressMode = .clampToEdge
        linearDescriptor.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: linearDescriptor)
    }

    private func ensureTargets(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if targetSize == size, colorTarget != nil { return }
        targetSize = size
        let width = Int(size.width), height = Int(size.height)

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        colorDescriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        colorDescriptor.sampleCount = sampleCount
        colorTarget = device.makeTexture(descriptor: colorDescriptor)

        if sampleCount > 1 {
            let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
            resolveDescriptor.usage = [.renderTarget, .shaderRead]
            resolveDescriptor.storageMode = .private
            resolveTarget = device.makeTexture(descriptor: resolveDescriptor)
        } else {
            resolveTarget = nil
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        depthDescriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        depthDescriptor.sampleCount = sampleCount
        depthTarget = device.makeTexture(descriptor: depthDescriptor)
    }

    // MARK: Instance assembly

    private struct Batch {
        var key: MeshKey
        var instances: [InstanceData]
    }

    private var geomScratch: [Double] = []
    private var geomTransforms: [simd_float4x4] = []

    private func normalMatrix(_ model: simd_float4x4) -> simd_float4x4 {
        let upper = simd_float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
        let inverseTranspose = upper.inverse.transpose
        return simd_float4x4(
            SIMD4<Float>(inverseTranspose.columns.0, 0),
            SIMD4<Float>(inverseTranspose.columns.1, 0),
            SIMD4<Float>(inverseTranspose.columns.2, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }

    private func buildBatches(world: World, settings: RenderSettings)
        -> (batches: [Batch], bounds: (min: SIMD3<Float>, max: SIMD3<Float>))
    {
        world.fillGeomTransforms(&geomTransforms, scratch: &geomScratch)
        let info = world.geomInfo

        var byKey: [MeshKey: [InstanceData]] = [:]
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for (index, geom) in info.enumerated() {
            guard index < geomTransforms.count else { break }
            var isPlane = false
            if case .plane = geom.shape { isPlane = true }
            let visible = geom.visible ? settings.showVisualGeometry : false
            let asCollision = geom.collidable && settings.showCollisionGeometry
            guard visible || asCollision else { continue }

            let (key, scale) = MeshLibrary.resolve(geom.shape)
            let model = geomTransforms[index] * Matrix.scale(scale)

            var instance = InstanceData()
            instance.model = model
            instance.normalMatrix = normalMatrix(model)
            let c = geom.appearance.color
            instance.baseColor = SIMD4<Float>(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
            instance.params = SIMD4<Float>(Float(geom.appearance.metallic),
                                           Float(geom.appearance.roughness),
                                           Float(geom.appearance.emissive),
                                           settings.selection.contains(index) ? 1 : 0)
            if asCollision && !visible {
                instance.baseColor = SIMD4<Float>(0.05, 0.55, 1.0, 0.35)
                instance.params.y = 0.9
            }
            byKey[key, default: []].append(instance)

            // Ground planes are shadow receivers, not shadow casters, and their
            // extent would blow out the light frustum if it had to contain them.
            guard !isPlane else { continue }
            let position = model.columns.3.xyz
            let radius = simd_length(scale) + 0.05
            lo = simd_min(lo, position - SIMD3<Float>(repeating: radius))
            hi = simd_max(hi, position + SIMD3<Float>(repeating: radius))
        }

        if lo.x > hi.x {
            lo = SIMD3<Float>(-1, -1, 0)
            hi = SIMD3<Float>(1, 1, 1)
        }
        return (byKey.map { Batch(key: $0.key, instances: $0.value) }, (lo, hi))
    }

    private func buildOverlay(world: World, settings: RenderSettings)
        -> (instances: [InstanceData], lines: [LineVertex])
    {
        var instances: [InstanceData] = []
        var lines: [LineVertex] = []

        if settings.showContacts {
            for contact in world.contacts() {
                let p = SIMD3<Float>(Float(contact.point.x), Float(contact.point.y),
                                     Float(contact.point.z))
                var instance = InstanceData()
                instance.model = Matrix.translation(p) * Matrix.scale(SIMD3<Float>(repeating: 0.012))
                instance.normalMatrix = matrix_identity_float4x4
                instance.baseColor = SIMD4<Float>(1.0, 0.42, 0.21, 0.95)
                instances.append(instance)

                if settings.showContactForces {
                    let f = SIMD3<Float>(Float(contact.force.x), Float(contact.force.y),
                                         Float(contact.force.z)) * settings.contactForceScale
                    let magnitude = simd_length(f)
                    guard magnitude > 1e-4 else { continue }
                    let tip = p + f
                    lines.append(LineVertex(position: SIMD4<Float>(p, 1),
                                            color: SIMD4<Float>(1.0, 0.42, 0.21, 0.9)))
                    lines.append(LineVertex(position: SIMD4<Float>(tip, 1),
                                            color: SIMD4<Float>(1.0, 0.75, 0.35, 0.25)))
                }
            }
        }

        if settings.showLinkFrames || settings.showCenterOfMass {
            let poses = world.linkPoses()
            for (index, pose) in poses.enumerated() {
                let origin = SIMD3<Float>(Float(pose.position.x), Float(pose.position.y),
                                          Float(pose.position.z))
                if settings.showLinkFrames {
                    let axisLength: Float = 0.08
                    let colors: [SIMD4<Float>] = [
                        SIMD4<Float>(0.94, 0.27, 0.34, 1),
                        SIMD4<Float>(0.20, 0.80, 0.45, 1),
                        SIMD4<Float>(0.20, 0.55, 1.00, 1),
                    ]
                    for axis in 0..<3 {
                        var unit = Vec3.zero
                        unit[axis] = 1
                        let dir = pose.applyVector(unit)
                        let tip = origin + SIMD3<Float>(Float(dir.x), Float(dir.y), Float(dir.z))
                            * axisLength
                        lines.append(LineVertex(position: SIMD4<Float>(origin, 1),
                                                color: colors[axis]))
                        lines.append(LineVertex(position: SIMD4<Float>(tip, 1), color: colors[axis]))
                    }
                }
                if settings.showTrails {
                    var trail = trails[index] ?? []
                    if trail.last.map({ simd_distance($0, origin) > 0.004 }) ?? true {
                        trail.append(origin)
                        if trail.count > 400 { trail.removeFirst(trail.count - 400) }
                        trails[index] = trail
                    }
                    if trail.count > 1 {
                        for i in 0..<(trail.count - 1) {
                            let fade = Float(i) / Float(trail.count)
                            let color = SIMD4<Float>(0.05, 0.55, 1.0, fade * 0.8)
                            lines.append(LineVertex(position: SIMD4<Float>(trail[i], 1),
                                                    color: color))
                            lines.append(LineVertex(position: SIMD4<Float>(trail[i + 1], 1),
                                                    color: color))
                        }
                    }
                }
            }
        } else if !settings.showTrails {
            trails.removeAll(keepingCapacity: true)
        }

        if settings.showCenterOfMass {
            let com = world.centerOfMass
            let p = SIMD3<Float>(Float(com.x), Float(com.y), Float(com.z))
            var instance = InstanceData()
            instance.model = Matrix.translation(p) * Matrix.scale(SIMD3<Float>(repeating: 0.03))
            instance.baseColor = SIMD4<Float>(1.0, 0.85, 0.2, 0.9)
            instances.append(instance)
        }

        return (instances, lines)
    }

    private func buffer(for key: MeshKey, instances: [InstanceData]) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        let needed = MemoryLayout<InstanceData>.stride * instances.count
        var buffer = instanceBuffers[key]
        if buffer == nil || buffer!.length < needed {
            buffer = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
            instanceBuffers[key] = buffer
        }
        guard let buffer else { return nil }
        instances.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: needed)
        }
        return buffer
    }

    // MARK: Draw

    public func draw(world: World, settings: RenderSettings, camera: OrbitCamera,
                     in view: MTKView) {
        let start = CACurrentMediaTime()
        guard let drawable = view.currentDrawable else { return }
        let size = view.drawableSize
        ensureTargets(size: size)
        guard let colorTarget, let depthTarget,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let aspect = Float(size.width / max(size.height, 1))
        let (batches, bounds) = buildBatches(world: world, settings: settings)
        let (overlayInstances, lines) = buildOverlay(world: world, settings: settings)

        var uniforms = FrameUniforms()
        uniforms.view = camera.viewMatrix
        uniforms.viewProjection = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
        uniforms.cameraPosition = SIMD4<Float>(camera.position, 1)

        let lightDirection = simd_normalize(SIMD3<Float>(
            cos(settings.lightAzimuth) * cos(settings.lightElevation),
            sin(settings.lightAzimuth) * cos(settings.lightElevation),
            sin(settings.lightElevation)))
        uniforms.lightDirection = SIMD4<Float>(lightDirection, settings.theme.lightIntensity)
        uniforms.lightColor = SIMD4<Float>(1.0, 0.98, 0.95, 1)
        uniforms.skyColor = settings.theme.skyAmbient
        uniforms.groundColor = settings.theme.groundAmbient
        uniforms.params = SIMD4<Float>(settings.theme.exposure, Float(world.time),
                                       1.0 / 2048.0, settings.theme.ambientIntensity)
        uniforms.gridColor = settings.theme.gridColor
        let cell = gridCell(for: camera.distance)
        uniforms.gridParams = SIMD4<Float>(cell, 5, camera.distance * 3.2,
                                           settings.showGrid ? 1 : 0)
        uniforms.lightViewProjection = shadowMatrix(bounds: bounds, lightDirection: lightDirection)

        lastInstanceCount = batches.reduce(0) { $0 + $1.instances.count }
        var drawCalls = 0

        // ── shadow pass ───────────────────────────────────────────────
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1.0
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.label = "kinetic.shadow"
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(shadowDepthState)
            encoder.setCullMode(.front)
            encoder.setDepthBias(0.0015, slopeScale: 2.0, clamp: 0.01)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            for batch in batches {
                guard let instanceBuffer = buffer(for: batch.key, instances: batch.instances)
                else { continue }
                let mesh = meshes.mesh(for: batch.key, world: world)
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0,
                                              instanceCount: batch.instances.count)
                drawCalls += 1
            }
            encoder.endEncoding()
        }

        // ── main pass ─────────────────────────────────────────────────
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = colorTarget
        scenePass.colorAttachments[0].loadAction = .clear
        let background = settings.theme.background
        scenePass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x), green: Double(background.y), blue: Double(background.z),
            alpha: 1)
        if sampleCount > 1, let resolveTarget {
            scenePass.colorAttachments[0].storeAction = .multisampleResolve
            scenePass.colorAttachments[0].resolveTexture = resolveTarget
        } else {
            scenePass.colorAttachments[0].storeAction = .store
        }
        scenePass.depthAttachment.texture = depthTarget
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1.0

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "kinetic.scene"
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(.back)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)

            encoder.setRenderPipelineState(scenePipeline)
            encoder.setDepthStencilState(sceneDepthState)
            encoder.setFragmentTexture(shadowMap, index: 0)
            encoder.setFragmentSamplerState(shadowSampler, index: 0)
            encoder.setTriangleFillMode(settings.wireframe ? .lines : .fill)
            for batch in batches {
                guard let instanceBuffer = buffer(for: batch.key, instances: batch.instances)
                else { continue }
                let mesh = meshes.mesh(for: batch.key, world: world)
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0,
                                              instanceCount: batch.instances.count)
                drawCalls += 1
            }
            encoder.setTriangleFillMode(.fill)

            // Overlay markers.
            // Overlays get their own instance buffer: the scene pass may still be
            // reading the shared sphere buffer when this encoder is recorded.
            if !overlayInstances.isEmpty {
                let needed = MemoryLayout<InstanceData>.stride * overlayInstances.count
                if overlayInstanceBuffer == nil || overlayInstanceBuffer!.length < needed {
                    overlayInstanceBuffer = device.makeBuffer(length: max(needed, 8192),
                                                              options: .storageModeShared)
                }
                let overlayBuffer = overlayInstanceBuffer!
                overlayInstances.withUnsafeBytes { source in
                    overlayBuffer.contents().copyMemory(from: source.baseAddress!,
                                                        byteCount: needed)
                }
                let mesh = meshes.mesh(for: .sphere, world: world)
                encoder.setRenderPipelineState(overlayPipeline)
                encoder.setDepthStencilState(overlayDepthState)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0,
                                              instanceCount: overlayInstances.count)
                drawCalls += 1
            }

            if !lines.isEmpty {
                let needed = MemoryLayout<LineVertex>.stride * lines.count
                if lineBuffer == nil || lineBuffer!.length < needed {
                    lineBuffer = device.makeBuffer(length: max(needed, 8192),
                                                   options: .storageModeShared)
                }
                if let lineBuffer {
                    lines.withUnsafeBytes { source in
                        lineBuffer.contents().copyMemory(from: source.baseAddress!,
                                                         byteCount: needed)
                    }
                    encoder.setRenderPipelineState(linePipeline)
                    encoder.setDepthStencilState(overlayDepthState)
                    encoder.setVertexBuffer(lineBuffer, offset: 0, index: 2)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
                    drawCalls += 1
                }
            }
            encoder.endEncoding()
        }

        // ── resolve + tonemap ─────────────────────────────────────────
        if let passDescriptor = view.currentRenderPassDescriptor {
            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0,
                                                                          alpha: 1)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.label = "kinetic.post"
                encoder.setRenderPipelineState(postPipeline)
                encoder.setFragmentTexture(sampleCount > 1 ? resolveTarget : colorTarget, index: 0)
                encoder.setFragmentSamplerState(linearSampler, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride,
                                          index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawCallCount = drawCalls
        lastDrawMilliseconds = (CACurrentMediaTime() - start) * 1000
    }


    /// Picks a 1-2-5 grid cell that keeps roughly 25 divisions across the view,
    /// so the grid stays readable from a tabletop scene up to a warehouse.
    private func gridCell(for distance: Float) -> Float {
        let target = max(distance, 0.2) / 22
        let exponent = floor(log10(target))
        let decade = pow(10, exponent)
        let normalized = target / decade
        let nice: Float = normalized < 1.5 ? 1 : (normalized < 3.5 ? 2 : (normalized < 7.5 ? 5 : 10))
        return nice * decade
    }

    /// Fits an orthographic light frustum around the scene bounds.
    private func shadowMatrix(bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                              lightDirection: SIMD3<Float>) -> simd_float4x4 {
        let center = (bounds.min + bounds.max) * 0.5
        let radius = max(simd_length(bounds.max - bounds.min) * 0.5, 1.0)
        let eye = center + lightDirection * (radius * 2.5)
        let view = Matrix.lookAt(eye: eye, target: center, up: SIMD3<Float>(0, 0, 1))
        let projection = Matrix.orthographic(left: -radius * 1.2, right: radius * 1.2,
                                             bottom: -radius * 1.2, top: radius * 1.2,
                                             near: 0.05, far: radius * 5.5)
        return projection * view
    }

    /// Renders one frame into an offscreen texture and returns it as a CGImage.
    /// Used by the CLI for headless screenshots and by camera sensors.
    public func snapshot(world: World, settings: RenderSettings, camera: OrbitCamera,
                         width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if arch(arm64)
        descriptor.storageMode = .shared
        #else
        descriptor.storageMode = .managed
        #endif
        guard let output = device.makeTexture(descriptor: descriptor) else { return nil }

        // Render through the standard path into an explicit target.
        ensureTargets(size: CGSize(width: width, height: height))
        guard let colorTarget, let depthTarget,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let aspect = Float(width) / Float(max(height, 1))
        let (batches, bounds) = buildBatches(world: world, settings: settings)
        var uniforms = FrameUniforms()
        uniforms.view = camera.viewMatrix
        uniforms.viewProjection = camera.projectionMatrix(aspect: aspect) * camera.viewMatrix
        uniforms.cameraPosition = SIMD4<Float>(camera.position, 1)
        let lightDirection = simd_normalize(SIMD3<Float>(
            cos(settings.lightAzimuth) * cos(settings.lightElevation),
            sin(settings.lightAzimuth) * cos(settings.lightElevation),
            sin(settings.lightElevation)))
        uniforms.lightDirection = SIMD4<Float>(lightDirection, settings.theme.lightIntensity)
        uniforms.lightColor = SIMD4<Float>(1.0, 0.98, 0.95, 1)
        uniforms.skyColor = settings.theme.skyAmbient
        uniforms.groundColor = settings.theme.groundAmbient
        uniforms.params = SIMD4<Float>(settings.theme.exposure, Float(world.time), 1.0 / 2048.0,
                                       settings.theme.ambientIntensity)
        uniforms.gridColor = settings.theme.gridColor
        uniforms.gridParams = SIMD4<Float>(gridCell(for: camera.distance), 5,
                                           camera.distance * 3.2, settings.showGrid ? 1 : 0)
        uniforms.lightViewProjection = shadowMatrix(bounds: bounds, lightDirection: lightDirection)

        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1.0
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setDepthStencilState(shadowDepthState)
            encoder.setCullMode(.front)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            for batch in batches {
                guard let instanceBuffer = buffer(for: batch.key, instances: batch.instances)
                else { continue }
                let mesh = meshes.mesh(for: batch.key, world: world)
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0,
                                              instanceCount: batch.instances.count)
            }
            encoder.endEncoding()
        }

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = colorTarget
        scenePass.colorAttachments[0].loadAction = .clear
        let background = settings.theme.background
        scenePass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x), green: Double(background.y), blue: Double(background.z),
            alpha: 1)
        if sampleCount > 1, let resolveTarget {
            scenePass.colorAttachments[0].storeAction = .multisampleResolve
            scenePass.colorAttachments[0].resolveTexture = resolveTarget
        } else {
            scenePass.colorAttachments[0].storeAction = .store
        }
        scenePass.depthAttachment.texture = depthTarget
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .dontCare
        scenePass.depthAttachment.clearDepth = 1.0

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(.back)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setRenderPipelineState(scenePipeline)
            encoder.setDepthStencilState(sceneDepthState)
            encoder.setFragmentTexture(shadowMap, index: 0)
            encoder.setFragmentSamplerState(shadowSampler, index: 0)
            for batch in batches {
                guard let instanceBuffer = buffer(for: batch.key, instances: batch.instances)
                else { continue }
                let mesh = meshes.mesh(for: batch.key, world: world)
                encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                              indexType: .uint32, indexBuffer: mesh.indexBuffer,
                                              indexBufferOffset: 0,
                                              instanceCount: batch.instances.count)
            }
            if settings.showGrid {
                encoder.setRenderPipelineState(gridPipeline)
                encoder.setDepthStencilState(gridDepthState)
                encoder.setCullMode(.none)
                var plane = SIMD4<Float>(camera.distance * 5.0, 0, 0, 0.0015)
                encoder.setVertexBytes(&plane, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            encoder.endEncoding()
        }

        let postPass = MTLRenderPassDescriptor()
        postPass.colorAttachments[0].texture = output
        postPass.colorAttachments[0].loadAction = .clear
        postPass.colorAttachments[0].storeAction = .store
        postPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: postPass) {
            encoder.setRenderPipelineState(postPipeline)
            encoder.setFragmentTexture(sampleCount > 1 ? resolveTarget : colorTarget, index: 0)
            encoder.setFragmentSamplerState(linearSampler, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        output.getBytes(&pixels, bytesPerRow: rowBytes,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // Metal hands back BGRA; CoreGraphics wants that spelled out explicitly.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
