// Author: Timur Isaev

Texture2D<float4> sourceTexture : register(t0);
SamplerState sourceSampler : register(s0);
RWStructuredBuffer<float> output : register(u0);

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    output[tid.x] =
        sourceTexture.SampleLevel(sourceSampler, float2(0.375f, 0.625f), 0.0f).x;
}
