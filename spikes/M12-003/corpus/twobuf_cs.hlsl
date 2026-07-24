RWStructuredBuffer<float> a : register(u0);
RWStructuredBuffer<float> b : register(u1);
[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID)
{
    b[tid.x] = a[tid.x] + b[tid.x];
}
