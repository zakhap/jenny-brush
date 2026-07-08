#include <metal_stdlib>
using namespace metal;

// =============================================================================
// One vertex/fragment pair (§11.3): an instanced unit quad, per-instance
// {center, halfSize, uvRect, pageIndex}, sampling a texture2d_array atlas.
// A second, non-array fragment variant blits the plain 2D committedTexture.
// =============================================================================

struct Uniforms {
    float2 canvasSize; // canvas px size, e.g. view points * K.canvasScale
};

// Per-instance quad data. `rotation` is a scaffolded hook for
// K.rotateToTangent (always 0 in MVP — never set away from identity).
struct StampInstance {
    float2 center;
    float2 halfSize;
    float2 uvMin;
    float2 uvMax;
    float rotation;
    uint page;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    uint page [[flat]];
};

// Shared unit-quad corners, in [-1, 1] x [-1, 1] (buffer(0)).
// Fed as a triangle strip: (-1,-1), (1,-1), (-1,1), (1,1).

vertex VertexOut stampVertex(uint vertexID [[vertex_id]],
                              uint instanceID [[instance_id]],
                              constant float2 *corners [[buffer(0)]],
                              constant StampInstance *instances [[buffer(1)]],
                              constant Uniforms &uniforms [[buffer(2)]]) {
    StampInstance inst = instances[instanceID];
    float2 corner = corners[vertexID];

    // Scaffolded rotate-to-tangent (K.rotateToTangent, off in MVP: rotation == 0).
    float c = cos(inst.rotation);
    float s = sin(inst.rotation);
    float2 rotated = float2(corner.x * c - corner.y * s, corner.x * s + corner.y * c);

    float2 px = inst.center + rotated * inst.halfSize;

    float2 ndc;
    ndc.x = (px.x / uniforms.canvasSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (px.y / uniforms.canvasSize.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    float2 uvT = (corner + float2(1.0, 1.0)) * 0.5;
    out.uv = mix(inst.uvMin, inst.uvMax, uvT);
    out.page = inst.page;
    return out;
}

fragment float4 stampFragment(VertexOut in [[stage_in]],
                               texture2d_array<float> atlas [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    // Premultiplied RGBA straight from the atlas.
    return atlas.sample(smp, in.uv, in.page);
}

fragment float4 blitFragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}
