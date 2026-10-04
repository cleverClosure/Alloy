// Author: Timur Isaev

RWStructuredBuffer<float> buf : register(u0);

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    buf[tid.x] = WaveActiveSum(buf[tid.x]);
}
