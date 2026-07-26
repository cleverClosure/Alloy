// Author: Timur Isaev

Texture2D<float4> sourceTexture : register(t0);
SamplerState sourceSampler : register(s0);
RWStructuredBuffer<float> output : register(u0);

[numthreads(64, 1, 1)] void main(uint3 tid : SV_DispatchThreadID)
{ output[tid.x] = sourceTexture.SampleLevel(sourceSampler, float2(0.5f, 0.5f), 1.0f).x; }
