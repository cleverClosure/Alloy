RWStructuredBuffer<uint> buf : register(u0);
[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    buf[tid.x] = buf[tid.x] * 3u + 7u;
}
