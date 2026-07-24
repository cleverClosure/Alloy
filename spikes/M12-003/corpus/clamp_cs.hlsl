RWStructuredBuffer<float> buf : register(u0);
[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    buf[tid.x] = max(min(buf[tid.x], 10.0f), -10.0f) * 0.5f;
}
