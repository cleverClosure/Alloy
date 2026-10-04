// Alloy Metal12 reference scene.
// Author: Timur Isaev

cbuffer Frame : register(b0)
{
    float4 params;
};

struct VSOut
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

VSOut vs_main(uint vertex_id : SV_VertexID)
{
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(-1.0, 3.0),
        float2(3.0, -1.0)
    };
    VSOut output;
    output.position = float4(positions[vertex_id], 0.0, 1.0);
    output.uv = positions[vertex_id] * float2(0.5, -0.5) + 0.5;
    return output;
}

float4 ps_main(VSOut input) : SV_Target
{
    float2 uv = input.uv;
    float2 centered = (uv - 0.5) * float2(params.y, 1.0);
    float radius = length(centered);
    float angle = atan2(centered.y, centered.x);
    float ring = 0.5 + 0.5 * cos(48.0 * radius - params.x * 6.2831853);
    float spokes = 0.5 + 0.5 * cos(12.0 * angle + params.x * 3.1415927);
    float checker = fmod(floor(uv.x * 12.0) + floor(uv.y * 7.0), 2.0);
    float3 gradient = float3(uv.x, uv.y, 1.0 - uv.x * 0.65);
    float3 accent = float3(0.08 + ring * 0.18, 0.35 + spokes * 0.35, 0.92);
    float vignette = saturate(1.2 - radius * 0.9);
    float3 color = lerp(gradient, accent, 0.28 + checker * 0.16) * vignette;
    float core = 1.0 - smoothstep(0.15, 0.155, radius);
    color = lerp(color, float3(1.0, 0.42, 0.12), core * (0.45 + ring * 0.35));
    return float4(saturate(color), 1.0);
}
