// Author: Timur Isaev

RWStructuredBuffer<uint> output : register(u0);

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    output[tid.x] = WaveGetLaneIndex();
}
