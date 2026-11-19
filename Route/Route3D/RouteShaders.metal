#include <metal_stdlib>
using namespace metal;

struct Camera {
    float4 rotation;  // cos(yaw), sin(yaw), cos(pitch), sin(pitch)
    float4 viewport;  // width, height, projected track span, camera perspective
    float4 scene;     // center x, center y, elevation scale, curtain depth
    float4 styling;   // point-to-pixel scale, reserved
};

struct CurtainVertex {
    float4 position [[position]];
    float drop;
};

struct StrokeVertex {
    float4 position [[position]];
    float2 local [[center_no_perspective]];
    float segmentLength [[flat]];
};

static float4 project(float3 point, constant Camera &camera) {
    float horizontal = dot(point.xz, camera.rotation.xy);
    float depth = dot(point.xz, float2(-camera.rotation.y, camera.rotation.x));
    float vertical = point.y * camera.rotation.z - depth * camera.rotation.w;
    float towardCamera = point.y * camera.rotation.w + depth * camera.rotation.z;
    float w = 1.0 - towardCamera * camera.viewport.w;
    float2 offset = float2(horizontal, vertical) * (2.0 * camera.viewport.z) / camera.viewport.xy;
    return float4(offset + camera.scene.xy * w, 0.5 * w - towardCamera * 0.3, w);
}

vertex CurtainVertex routeCurtainVertex(
    uint id [[vertex_id]],
    device const float4 *points [[buffer(0)]],
    constant Camera &camera [[buffer(1)]]
) {
    float drop = float(id % 2);
    float3 point = points[id / 2].xyz;
    point.y = point.y * camera.scene.z - drop * camera.scene.w;
    return { project(point, camera), drop };
}

fragment half4 routeCurtainFragment(
    CurtainVertex in [[stage_in]], constant Camera &camera [[buffer(1)]]
) {
    half opacity = half(0.41 * camera.scene.z * pow(max(1.0 - in.drop, 0.0), 2.7));
    return half4(half3(0.90) * opacity, opacity);
}

static float2 screenPoint(float4 clip, float2 viewport) {
    return clip.xy / clip.w * viewport * 0.5;
}

// Each segment is a screen-space capsule. Round caps join the GPX switchbacks
// without the miter spikes that occur when the route points nearly back at itself.
vertex StrokeVertex routeStrokeVertex(
    uint corner [[vertex_id]],
    uint segment [[instance_id]],
    device const float4 *points [[buffer(0)]],
    constant Camera &camera [[buffer(1)]]
) {
    float3 a = points[segment].xyz;
    float3 b = points[segment + 1].xyz;
    a.y *= camera.scene.z;
    b.y *= camera.scene.z;
    float4 start = project(a, camera);
    float4 end = project(b, camera);
    float2 viewport = camera.viewport.xy;
    float2 delta = screenPoint(end, viewport) - screenPoint(start, viewport);
    float segmentLength = length(delta);
    float2 tangent = segmentLength > 0.001 ? delta / segmentLength : float2(1.0, 0.0);
    float2 normal = float2(-tangent.y, tangent.x);
    float radius = 4.5 * camera.styling.x;
    bool atEnd = corner >= 2;
    float4 clip = atEnd ? end : start;
    float along = atEnd ? radius : -radius;
    float across = corner % 2 == 0 ? -radius : radius;
    clip.xy += (tangent * along + normal * across) * (2.0 * clip.w) / viewport;
    return { clip, float2(atEnd ? segmentLength + along : along, across), segmentLength };
}

fragment half4 routeStrokeFragment(
    StrokeVertex in [[stage_in]], constant Camera &camera [[buffer(1)]]
) {
    float along = in.local.x - clamp(in.local.x, 0.0, in.segmentLength);
    float distance = length(float2(along, in.local.y)) / camera.styling.x;
    float feather = max(0.5 * fwidth(distance), 0.18);
    float core = 1.0 - smoothstep(1.06 - feather, 1.06 + feather, distance);
    float glow = 0.17 * exp(-0.65 * distance * distance) * (1.0 - smoothstep(3.4, 4.5, distance));
    half opacity = half(max(core, glow));
    return half4(half3(0.995, 0.992, 0.980) * opacity, opacity);
}
