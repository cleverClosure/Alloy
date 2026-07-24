RWStructuredBuffer<float> buf : register(u0);
[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    float v = buf[tid.x];
    buf[tid.x] = v > 0.5f ? v * 2.0f : v - 1.0f;
}
