//
//  kinetic.metal
//  KineticRender
//
//  Forward PBR renderer. Compiled at runtime from this source so the package
//  builds identically under `swift build` and Xcode without a metallib step.
//
//  Passes:
//    shadow_vertex          depth-only render from the light
//    scene_vertex/fragment  instanced Cook-Torrance GGX + PCF shadows
//    grid_vertex/fragment   analytic, screen-space-antialiased ground grid
//    line_vertex/fragment   debug lines (contacts, axes, trails, wireframe)
//    overlay_*              unlit instanced markers
//    post_*                 fullscreen ACES tonemap + vignette resolve
//

#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProjection;
    float4x4 view;
    float4x4 lightViewProjection;
    float4 cameraPosition;
    float4 lightDirection;   // xyz: direction TOWARD the light, w: intensity
    float4 lightColor;
    float4 skyColor;
    float4 groundColor;
    float4 params;           // x: exposure, y: time, z: shadowTexel, w: ambient
    float4 gridParams;       // x: cell, y: majorEvery, z: fade distance, w: opacity
    float4 gridColor;
};

struct InstanceData {
    float4x4 model;
    float4x4 normalMatrix;
    float4 baseColor;
    float4 params;           // x: metallic, y: roughness, z: emissive, w: selection
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct SceneVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float4 color;
    float4 params;
    float4 lightSpacePosition;
};

// ── shadow pass ─────────────────────────────────────────────────────────

vertex float4 shadow_vertex(VertexIn in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(1)]],
                            constant InstanceData *instances [[buffer(2)]],
                            uint instanceID [[instance_id]]) {
    float4 world = instances[instanceID].model * float4(in.position, 1.0);
    return frame.lightViewProjection * world;
}

// ── main scene pass ─────────────────────────────────────────────────────

vertex SceneVertexOut scene_vertex(VertexIn in [[stage_in]],
                                   constant FrameUniforms &frame [[buffer(1)]],
                                   constant InstanceData *instances [[buffer(2)]],
                                   uint instanceID [[instance_id]]) {
    InstanceData instance = instances[instanceID];
    float4 world = instance.model * float4(in.position, 1.0);
    SceneVertexOut out;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = normalize((instance.normalMatrix * float4(in.normal, 0.0)).xyz);
    out.color = instance.baseColor;
    out.params = instance.params;
    out.lightSpacePosition = frame.lightViewProjection * world;
    return out;
}

static float distributionGGX(float3 n, float3 h, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float ndoth = max(dot(n, h), 0.0);
    float d = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / max(M_PI_F * d * d, 1e-6);
}

static float geometrySchlick(float ndotv, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return ndotv / (ndotv * (1.0 - k) + k);
}

static float3 fresnelSchlick(float cosTheta, float3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

static float sampleShadow(depth2d<float> shadowMap, sampler shadowSampler,
                          float4 lightSpacePosition, float texel, float ndotl) {
    float3 proj = lightSpacePosition.xyz / max(lightSpacePosition.w, 1e-6);
    float2 uv = proj.xy * float2(0.5, -0.5) + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || proj.z > 1.0) return 1.0;

    float bias = mix(0.0025, 0.0006, ndotl);
    float shadow = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 offset = float2(x, y) * texel;
            float depth = shadowMap.sample(shadowSampler, uv + offset);
            shadow += (proj.z - bias) <= depth ? 1.0 : 0.0;
        }
    }
    return shadow / 9.0;
}

// Two-tone hemispheric ambient: a stand-in for an IBL probe that costs nothing
// to author and reads correctly in both light and dark UI themes.
static float3 hemisphere(float3 n, float3 sky, float3 ground) {
    float t = n.z * 0.5 + 0.5;
    return mix(ground, sky, t);
}

fragment float4 scene_fragment(SceneVertexOut in [[stage_in]],
                               constant FrameUniforms &frame [[buffer(1)]],
                               depth2d<float> shadowMap [[texture(0)]],
                               sampler shadowSampler [[sampler(0)]]) {
    float3 albedo = in.color.rgb;
    float metallic = clamp(in.params.x, 0.0, 1.0);
    float roughness = clamp(in.params.y, 0.045, 1.0);
    float emissive = in.params.z;
    float selection = in.params.w;

    float3 n = normalize(in.normal);
    float3 v = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 l = normalize(frame.lightDirection.xyz);
    float3 h = normalize(v + l);

    float ndotl = max(dot(n, l), 0.0);
    float ndotv = max(dot(n, v), 1e-4);

    float3 f0 = mix(float3(0.04), albedo, metallic);
    float ndf = distributionGGX(n, h, roughness);
    float g = geometrySchlick(ndotv, roughness) * geometrySchlick(ndotl, roughness);
    float3 f = fresnelSchlick(max(dot(h, v), 0.0), f0);

    float3 specular = (ndf * g * f) / max(4.0 * ndotv * ndotl, 1e-4);
    float3 kd = (1.0 - f) * (1.0 - metallic);

    float shadow = sampleShadow(shadowMap, shadowSampler, in.lightSpacePosition,
                                frame.params.z, ndotl);
    float3 radiance = frame.lightColor.rgb * frame.lightDirection.w * shadow;
    float3 direct = (kd * albedo / M_PI_F + specular) * radiance * ndotl;

    float3 ambientColor = hemisphere(n, frame.skyColor.rgb, frame.groundColor.rgb);
    // Cheap specular occlusion keeps grazing angles from blowing out.
    float horizon = clamp(1.0 - roughness, 0.0, 1.0);
    float3 ambient = ambientColor * albedo * frame.params.w * (1.0 - metallic * 0.5)
                   + ambientColor * f0 * frame.params.w * horizon * 0.6;

    float3 color = direct + ambient + albedo * emissive;

    // Selection rim light.
    if (selection > 0.0) {
        float rim = pow(1.0 - ndotv, 2.5);
        color += float3(0.05, 0.55, 1.0) * rim * selection * 2.2;
    }

    return float4(color, in.color.a);
}

// ── ground grid ─────────────────────────────────────────────────────────

struct GridVertexOut {
    float4 position [[position]];
    float3 worldPosition;
};

vertex GridVertexOut grid_vertex(uint vertexID [[vertex_id]],
                                 constant FrameUniforms &frame [[buffer(1)]],
                                 constant float4 &plane [[buffer(2)]]) {
    // Fullscreen triangle projected onto the z = plane.w plane.
    float2 corners[6] = {float2(-1, -1), float2(1, -1), float2(1, 1),
                         float2(-1, -1), float2(1, 1), float2(-1, 1)};
    float2 c = corners[vertexID];
    float extent = plane.x;
    float3 world = float3(c.x * extent, c.y * extent, plane.w);
    GridVertexOut out;
    out.position = frame.viewProjection * float4(world, 1.0);
    out.worldPosition = world;
    return out;
}

fragment float4 grid_fragment(GridVertexOut in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(1)]]) {
    float cell = frame.gridParams.x;
    float majorEvery = frame.gridParams.y;
    float fadeDistance = frame.gridParams.z;
    float opacity = frame.gridParams.w;

    float2 coord = in.worldPosition.xy / cell;
    float2 derivative = fwidth(coord);
    float2 grid = abs(fract(coord - 0.5) - 0.5) / max(derivative, 1e-6);
    float line = min(grid.x, grid.y);
    float minor = 1.0 - min(line, 1.0);

    float2 majorCoord = in.worldPosition.xy / (cell * majorEvery);
    float2 majorDerivative = fwidth(majorCoord);
    float2 majorGrid = abs(fract(majorCoord - 0.5) - 0.5) / max(majorDerivative, 1e-6);
    float major = 1.0 - min(min(majorGrid.x, majorGrid.y), 1.0);

    float distance = length(in.worldPosition.xy - frame.cameraPosition.xy);
    float fade = 1.0 - smoothstep(fadeDistance * 0.35, fadeDistance, distance);

    float3 color = frame.gridColor.rgb;
    float alpha = (minor * 0.35 + major * 0.85) * fade * opacity;

    // Axis lines: X in red, Y in green, matched to the inspector's axis chips.
    float axisWidth = max(derivative.x, derivative.y) * cell * 1.2;
    if (abs(in.worldPosition.y) < axisWidth) {
        color = mix(color, float3(0.94, 0.27, 0.34), 0.85);
        alpha = max(alpha, 0.7 * fade);
    }
    if (abs(in.worldPosition.x) < axisWidth) {
        color = mix(color, float3(0.20, 0.80, 0.45), 0.85);
        alpha = max(alpha, 0.7 * fade);
    }

    if (alpha < 0.001) discard_fragment();
    return float4(color, alpha);
}

// ── debug lines ─────────────────────────────────────────────────────────

struct LineVertex {
    float4 position;
    float4 color;
};

struct LineVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex LineVertexOut line_vertex(uint vertexID [[vertex_id]],
                                 constant FrameUniforms &frame [[buffer(1)]],
                                 constant LineVertex *vertices [[buffer(2)]]) {
    LineVertexOut out;
    out.position = frame.viewProjection * float4(vertices[vertexID].position.xyz, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 line_fragment(LineVertexOut in [[stage_in]]) {
    return in.color;
}

// ── unlit overlay instances (contact markers, gizmos) ───────────────────

struct OverlayVertexOut {
    float4 position [[position]];
    float4 color;
    float3 normal;
};

vertex OverlayVertexOut overlay_vertex(VertexIn in [[stage_in]],
                                       constant FrameUniforms &frame [[buffer(1)]],
                                       constant InstanceData *instances [[buffer(2)]],
                                       uint instanceID [[instance_id]]) {
    InstanceData instance = instances[instanceID];
    float4 world = instance.model * float4(in.position, 1.0);
    OverlayVertexOut out;
    out.position = frame.viewProjection * world;
    out.color = instance.baseColor;
    out.normal = normalize((instance.normalMatrix * float4(in.normal, 0.0)).xyz);
    return out;
}

fragment float4 overlay_fragment(OverlayVertexOut in [[stage_in]],
                                 constant FrameUniforms &frame [[buffer(1)]]) {
    float shade = 0.55 + 0.45 * max(dot(normalize(in.normal),
                                        normalize(frame.lightDirection.xyz)), 0.0);
    return float4(in.color.rgb * shade, in.color.a);
}

// ── post processing ─────────────────────────────────────────────────────

struct PostVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostVertexOut post_vertex(uint vertexID [[vertex_id]]) {
    float2 corners[6] = {float2(-1, -1), float2(3, -1), float2(-1, 3),
                         float2(-1, -1), float2(3, -1), float2(-1, 3)};
    float2 c = corners[vertexID % 3];
    PostVertexOut out;
    out.position = float4(c, 0.0, 1.0);
    out.uv = c * float2(0.5, -0.5) + 0.5;
    return out;
}

// Narkowicz's ACES approximation: cheap, and close enough for a viewport.
static float3 acesFilm(float3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

fragment float4 post_fragment(PostVertexOut in [[stage_in]],
                              constant FrameUniforms &frame [[buffer(1)]],
                              texture2d<float> source [[texture(0)]],
                              sampler linearSampler [[sampler(0)]]) {
    float3 color = source.sample(linearSampler, in.uv).rgb;
    color *= frame.params.x;
    color = acesFilm(color);
    float2 centered = in.uv - 0.5;
    float vignette = 1.0 - dot(centered, centered) * 0.35;
    color *= vignette;
    return float4(pow(color, float3(1.0 / 2.2)), 1.0);
}
