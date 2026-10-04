// Author: Timur Isaev

RWStructuredBuffer<float> buf : register(u0);

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float value = buf[tid.x];
    buf[tid.x] = value > 0.5f ? value * 2.0f : value - 1.0f;
}
