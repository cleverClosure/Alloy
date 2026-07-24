/*
 * GFX-001 x64 D3D11 gate-4 measured scene.
 * Author: Timur Isaev
 *
 * A scene-shaped workload with the doc-16 metrics: 202 draws per frame
 * (100 opaque depth-tested quads, 100 alpha-blended quads, 2 depth-proof
 * anchor quads), each draw preceded by a dynamic constant-buffer
 * Map(DISCARD) update - the per-draw hot path real engines hammer.
 * 60 warmup frames, 600 measured frames at 1280x720, no vsync.
 *
 * Reports first-frame time (cold pipeline compile), frame percentiles,
 * and process memory at the start and end of the measured window.
 * Self-verifies with a readback of the anchor corner: a red quad at
 * z=0.3 drawn before a blue quad at z=0.7 must stay red, which proves
 * depth rejection worked all run.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <d3d11.h>
#include <d3dcompiler.h>
#include <math.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#define WIDTH 1280
#define HEIGHT 720
#define WARMUP_FRAMES 60
#define MEASURED_FRAMES 600
#define OPAQUE_DRAWS 100
#define BLENDED_DRAWS 100

static const float clear_color[4] = {0.1f, 0.1f, 0.12f, 1.0f};

static const char shader_source[] =
    "cbuffer scene_cb : register(b0)\n"
    "{\n"
    "    row_major float4x4 transform;\n"
    "    float4 tint;\n"
    "};\n"
    "struct vs_in { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "struct vs_out { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
    "vs_out vs_main(vs_in i)\n"
    "{\n"
    "    vs_out o;\n"
    "    o.pos = mul(i.pos, transform);\n"
    "    o.uv = i.uv;\n"
    "    return o;\n"
    "}\n"
    "Texture2D tex : register(t0);\n"
    "SamplerState samp : register(s0);\n"
    "float4 ps_tex(vs_out i) : SV_Target\n"
    "{\n"
    "    return tex.Sample(samp, i.uv) * tint;\n"
    "}\n"
    "float4 ps_flat(vs_out i) : SV_Target\n"
    "{\n"
    "    return tint;\n"
    "}\n";

struct vertex
{
    float x, y, z, w;
    float u, v;
};

static const struct vertex quad_verts[] = {
    {-1.0f, -1.0f, 0.0f, 1.0f, 0.0f, 1.0f},
    {-1.0f, 1.0f, 0.0f, 1.0f, 0.0f, 0.0f},
    {1.0f, -1.0f, 0.0f, 1.0f, 1.0f, 1.0f},
    {1.0f, 1.0f, 0.0f, 1.0f, 1.0f, 0.0f},
};

struct scene_cb
{
    float transform[4][4];
    float tint[4];
};

/* 2x2 BGRA texels, sampled linearly for a soft checker */
static const unsigned char texels[2][8] = {
    {64, 64, 255, 255, 64, 255, 64, 255},
    {255, 64, 64, 255, 255, 255, 255, 255},
};

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(window, message, wparam, lparam);
}

static ID3DBlob *compile(const char *entry, const char *target)
{
    ID3DBlob *blob = NULL, *errors = NULL;
    HRESULT result = D3DCompile(shader_source, sizeof(shader_source) - 1, NULL, NULL, NULL, entry,
                                target, 0, 0, &blob, &errors);

    if (FAILED(result))
    {
        printf("compile %s failed: %08lx\n%s\n", entry, (unsigned long)result,
               errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "(no log)");
        return NULL;
    }
    return blob;
}

static void make_transform(struct scene_cb *cb, float scale, float angle, float tx, float ty,
                           float tz)
{
    float c = cosf(angle), s = sinf(angle);

    memset(cb->transform, 0, sizeof(cb->transform));
    cb->transform[0][0] = scale * c;
    cb->transform[0][1] = scale * s;
    cb->transform[1][0] = -scale * s;
    cb->transform[1][1] = scale * c;
    cb->transform[2][2] = 1.0f;
    cb->transform[3][0] = tx;
    cb->transform[3][1] = ty;
    cb->transform[3][2] = tz;
    cb->transform[3][3] = 1.0f;
}

static int compare_double(const void *a, const void *b)
{
    double da = *(const double *)a, db = *(const double *)b;

    return da < db ? -1 : da > db ? 1 : 0;
}

static double mem_mb(SIZE_T bytes)
{
    return (double)bytes / (1024.0 * 1024.0);
}

int main(void)
{
    WNDCLASSW window_class = {0};
    DXGI_SWAP_CHAIN_DESC swap_desc = {0};
    D3D11_BUFFER_DESC buffer_desc = {0};
    D3D11_SUBRESOURCE_DATA init_data = {0};
    D3D11_TEXTURE2D_DESC tex_desc = {0};
    D3D11_TEXTURE2D_DESC depth_desc = {0};
    D3D11_TEXTURE2D_DESC staging_desc;
    D3D11_SAMPLER_DESC sampler_desc = {0};
    D3D11_DEPTH_STENCIL_DESC ds_desc = {0};
    D3D11_BLEND_DESC blend_desc = {0};
    D3D11_MAPPED_SUBRESOURCE mapped;
    D3D11_VIEWPORT viewport = {0.0f, 0.0f, (float)WIDTH, (float)HEIGHT, 0.0f, 1.0f};
    D3D11_INPUT_ELEMENT_DESC layout_desc[2] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0},
    };
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    D3D_FEATURE_LEVEL got_level;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL;
    ID3D11Texture2D *depth_texture = NULL;
    ID3D11Texture2D *staging = NULL;
    ID3D11Texture2D *texture = NULL;
    ID3D11RenderTargetView *target_view = NULL;
    ID3D11DepthStencilView *depth_view = NULL;
    ID3D11ShaderResourceView *texture_view = NULL;
    ID3D11VertexShader *vertex_shader = NULL;
    ID3D11PixelShader *tex_shader = NULL;
    ID3D11PixelShader *flat_shader = NULL;
    ID3D11InputLayout *input_layout = NULL;
    ID3D11Buffer *vertex_buffer = NULL;
    ID3D11Buffer *constant_buffer = NULL;
    ID3D11SamplerState *sampler = NULL;
    ID3D11DepthStencilState *ds_opaque = NULL;
    ID3D11DepthStencilState *ds_readonly = NULL;
    ID3D11BlendState *blend_on = NULL;
    ID3DBlob *vs_blob, *ps_tex_blob, *ps_flat_blob;
    PROCESS_MEMORY_COUNTERS mem_start, mem_end, mem_frame;
    SIZE_T mem_prev_pagefile = 0;
    LARGE_INTEGER qpc_freq, qpc_prev, qpc_now, qpc_device, qpc_first;
    static double frame_ms[MEASURED_FRAMES];
    struct scene_cb cb;
    UINT stride = sizeof(struct vertex), offset = 0;
    const unsigned char *pixel;
    unsigned int frame, draw, anchor_x, anchor_y;
    double first_frame_ms, mean_ms;
    HWND window;
    HRESULT result;
    MSG message;

    setvbuf(stdout, NULL, _IONBF, 0);
    QueryPerformanceFrequency(&qpc_freq);

    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = L"gfx001_d3d11_scene";
    if (!RegisterClassW(&window_class))
        return 1;
    window =
        CreateWindowW(window_class.lpszClassName, L"gfx-001 d3d11 scene", WS_POPUP | WS_VISIBLE,
                      100, 100, WIDTH, HEIGHT, NULL, NULL, window_class.hInstance, NULL);
    if (!window)
        return 2;
    puts("stage: window created");

    swap_desc.BufferCount = 2;
    swap_desc.BufferDesc.Width = WIDTH;
    swap_desc.BufferDesc.Height = HEIGHT;
    swap_desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    swap_desc.BufferDesc.RefreshRate.Numerator = 60;
    swap_desc.BufferDesc.RefreshRate.Denominator = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.OutputWindow = window;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.Windowed = TRUE;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    QueryPerformanceCounter(&qpc_device);
    result = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1,
                                           D3D11_SDK_VERSION, &swap_desc, &swapchain, &device,
                                           &got_level, &context);
    if (FAILED(result))
    {
        printf("device creation failed: %08lx\n", (unsigned long)result);
        return 3;
    }
    puts("stage: device created");

    if (!(vs_blob = compile("vs_main", "vs_5_0")))
        return 4;
    if (!(ps_tex_blob = compile("ps_tex", "ps_5_0")))
        return 4;
    if (!(ps_flat_blob = compile("ps_flat", "ps_5_0")))
        return 4;
    result =
        ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_blob),
                                        ID3D10Blob_GetBufferSize(vs_blob), NULL, &vertex_shader);
    if (FAILED(result))
        return 5;
    result =
        ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_tex_blob),
                                       ID3D10Blob_GetBufferSize(ps_tex_blob), NULL, &tex_shader);
    if (FAILED(result))
        return 5;
    result =
        ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_flat_blob),
                                       ID3D10Blob_GetBufferSize(ps_flat_blob), NULL, &flat_shader);
    if (FAILED(result))
        return 5;
    result =
        ID3D11Device_CreateInputLayout(device, layout_desc, 2, ID3D10Blob_GetBufferPointer(vs_blob),
                                       ID3D10Blob_GetBufferSize(vs_blob), &input_layout);
    if (FAILED(result))
        return 5;

    buffer_desc.ByteWidth = sizeof(quad_verts);
    buffer_desc.Usage = D3D11_USAGE_IMMUTABLE;
    buffer_desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    init_data.pSysMem = quad_verts;
    result = ID3D11Device_CreateBuffer(device, &buffer_desc, &init_data, &vertex_buffer);
    if (FAILED(result))
        return 6;

    buffer_desc.ByteWidth = sizeof(struct scene_cb);
    buffer_desc.Usage = D3D11_USAGE_DYNAMIC;
    buffer_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    buffer_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    result = ID3D11Device_CreateBuffer(device, &buffer_desc, NULL, &constant_buffer);
    if (FAILED(result))
    {
        printf("create cbuffer failed: %08lx\n", (unsigned long)result);
        return 6;
    }

    tex_desc.Width = 2;
    tex_desc.Height = 2;
    tex_desc.MipLevels = 1;
    tex_desc.ArraySize = 1;
    tex_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    tex_desc.SampleDesc.Count = 1;
    tex_desc.Usage = D3D11_USAGE_IMMUTABLE;
    tex_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    init_data.pSysMem = texels;
    init_data.SysMemPitch = 8;
    result = ID3D11Device_CreateTexture2D(device, &tex_desc, &init_data, &texture);
    if (FAILED(result))
        return 7;
    result = ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, NULL,
                                                   &texture_view);
    if (FAILED(result))
        return 7;

    sampler_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sampler_desc.AddressU = D3D11_TEXTURE_ADDRESS_WRAP;
    sampler_desc.AddressV = D3D11_TEXTURE_ADDRESS_WRAP;
    sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    sampler_desc.MaxLOD = D3D11_FLOAT32_MAX;
    result = ID3D11Device_CreateSamplerState(device, &sampler_desc, &sampler);
    if (FAILED(result))
        return 8;

    depth_desc.Width = WIDTH;
    depth_desc.Height = HEIGHT;
    depth_desc.MipLevels = 1;
    depth_desc.ArraySize = 1;
    depth_desc.Format = DXGI_FORMAT_D32_FLOAT;
    depth_desc.SampleDesc.Count = 1;
    depth_desc.Usage = D3D11_USAGE_DEFAULT;
    depth_desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    result = ID3D11Device_CreateTexture2D(device, &depth_desc, NULL, &depth_texture);
    if (FAILED(result))
    {
        printf("create depth texture failed: %08lx\n", (unsigned long)result);
        return 9;
    }
    result = ID3D11Device_CreateDepthStencilView(device, (ID3D11Resource *)depth_texture, NULL,
                                                 &depth_view);
    if (FAILED(result))
    {
        printf("create dsv failed: %08lx\n", (unsigned long)result);
        return 9;
    }

    ds_desc.DepthEnable = TRUE;
    ds_desc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ALL;
    ds_desc.DepthFunc = D3D11_COMPARISON_LESS;
    result = ID3D11Device_CreateDepthStencilState(device, &ds_desc, &ds_opaque);
    if (FAILED(result))
        return 10;
    ds_desc.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    result = ID3D11Device_CreateDepthStencilState(device, &ds_desc, &ds_readonly);
    if (FAILED(result))
        return 10;

    blend_desc.RenderTarget[0].BlendEnable = TRUE;
    blend_desc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    blend_desc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend_desc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend_desc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_ZERO;
    blend_desc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend_desc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    result = ID3D11Device_CreateBlendState(device, &blend_desc, &blend_on);
    if (FAILED(result))
        return 11;

    result = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    if (FAILED(result))
        return 12;
    result = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL,
                                                 &target_view);
    if (FAILED(result))
        return 12;

    ID3D11Texture2D_GetDesc(backbuffer, &staging_desc);
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;
    result = ID3D11Device_CreateTexture2D(device, &staging_desc, NULL, &staging);
    if (FAILED(result))
        return 12;
    puts("stage: scene resources ready");

    ID3D11DeviceContext_IASetInputLayout(context, input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    ID3D11DeviceContext_IASetVertexBuffers(context, 0, 1, &vertex_buffer, &stride, &offset);
    ID3D11DeviceContext_VSSetShader(context, vertex_shader, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(context, 0, 1, &constant_buffer);
    ID3D11DeviceContext_PSSetConstantBuffers(context, 0, 1, &constant_buffer);
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 1, &texture_view);
    ID3D11DeviceContext_PSSetSamplers(context, 0, 1, &sampler);
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);

    GetProcessMemoryInfo(GetCurrentProcess(), &mem_start, sizeof(mem_start));
    QueryPerformanceCounter(&qpc_prev);
    qpc_first = qpc_prev;

    for (frame = 0; frame < WARMUP_FRAMES + MEASURED_FRAMES; frame++)
    {
        float angle = (float)frame * 0.01f;

        ID3D11DeviceContext_ClearRenderTargetView(context, target_view, clear_color);
        ID3D11DeviceContext_ClearDepthStencilView(context, depth_view, D3D11_CLEAR_DEPTH, 1.0f, 0);
        ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target_view, depth_view);

        /* opaque pass: textured, depth write, no blend */
        ID3D11DeviceContext_OMSetDepthStencilState(context, ds_opaque, 0);
        ID3D11DeviceContext_OMSetBlendState(context, NULL, NULL, 0xffffffff);
        ID3D11DeviceContext_PSSetShader(context, tex_shader, NULL, 0);
        for (draw = 0; draw < OPAQUE_DRAWS; draw++)
        {
            float t = (float)draw / OPAQUE_DRAWS;

            make_transform(&cb, 0.08f, angle + t * 6.28318f, 0.8f * cosf(t * 6.28318f + angle),
                           0.7f * sinf(t * 6.28318f + angle), 0.1f + 0.8f * t);
            cb.tint[0] = 0.5f + 0.5f * t;
            cb.tint[1] = 1.0f - 0.5f * t;
            cb.tint[2] = 0.8f;
            cb.tint[3] = 1.0f;
            result = ID3D11DeviceContext_Map(context, (ID3D11Resource *)constant_buffer, 0,
                                             D3D11_MAP_WRITE_DISCARD, 0, &mapped);
            if (FAILED(result))
                return 13;
            memcpy(mapped.pData, &cb, sizeof(cb));
            ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)constant_buffer, 0);
            ID3D11DeviceContext_Draw(context, 4, 0);
        }

        /* blended pass: textured, depth read-only, alpha blend */
        ID3D11DeviceContext_OMSetDepthStencilState(context, ds_readonly, 0);
        ID3D11DeviceContext_OMSetBlendState(context, blend_on, NULL, 0xffffffff);
        for (draw = 0; draw < BLENDED_DRAWS; draw++)
        {
            float t = (float)draw / BLENDED_DRAWS;

            make_transform(&cb, 0.12f, -angle - t * 6.28318f, 0.6f * sinf(t * 12.56636f - angle),
                           0.5f * cosf(t * 12.56636f - angle), 0.05f + 0.9f * t);
            cb.tint[0] = t;
            cb.tint[1] = 0.4f;
            cb.tint[2] = 1.0f - t;
            cb.tint[3] = 0.5f;
            result = ID3D11DeviceContext_Map(context, (ID3D11Resource *)constant_buffer, 0,
                                             D3D11_MAP_WRITE_DISCARD, 0, &mapped);
            if (FAILED(result))
                return 13;
            memcpy(mapped.pData, &cb, sizeof(cb));
            ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)constant_buffer, 0);
            ID3D11DeviceContext_Draw(context, 4, 0);
        }

        /* anchor pass: flat shaded, depth write, no blend; red in front of blue */
        ID3D11DeviceContext_OMSetDepthStencilState(context, ds_opaque, 0);
        ID3D11DeviceContext_OMSetBlendState(context, NULL, NULL, 0xffffffff);
        ID3D11DeviceContext_PSSetShader(context, flat_shader, NULL, 0);
        make_transform(&cb, 0.05f, 0.0f, -0.9f, -0.85f, 0.3f);
        cb.tint[0] = 1.0f;
        cb.tint[1] = 0.0f;
        cb.tint[2] = 0.0f;
        cb.tint[3] = 1.0f;
        result = ID3D11DeviceContext_Map(context, (ID3D11Resource *)constant_buffer, 0,
                                         D3D11_MAP_WRITE_DISCARD, 0, &mapped);
        if (FAILED(result))
            return 13;
        memcpy(mapped.pData, &cb, sizeof(cb));
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)constant_buffer, 0);
        ID3D11DeviceContext_Draw(context, 4, 0);
        make_transform(&cb, 0.05f, 0.0f, -0.9f, -0.85f, 0.7f);
        cb.tint[0] = 0.0f;
        cb.tint[1] = 0.0f;
        cb.tint[2] = 1.0f;
        cb.tint[3] = 1.0f;
        result = ID3D11DeviceContext_Map(context, (ID3D11Resource *)constant_buffer, 0,
                                         D3D11_MAP_WRITE_DISCARD, 0, &mapped);
        if (FAILED(result))
            return 13;
        memcpy(mapped.pData, &cb, sizeof(cb));
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)constant_buffer, 0);
        ID3D11DeviceContext_Draw(context, 4, 0);

        result = IDXGISwapChain_Present(swapchain, 0, 0);
        if (FAILED(result))
        {
            printf("present failed at frame %u: %08lx\n", frame, (unsigned long)result);
            return 14;
        }

        QueryPerformanceCounter(&qpc_now);
        if (frame == 0)
            first_frame_ms =
                (double)(qpc_now.QuadPart - qpc_device.QuadPart) * 1000.0 / qpc_freq.QuadPart;
        if (frame >= WARMUP_FRAMES)
            frame_ms[frame - WARMUP_FRAMES] =
                (double)(qpc_now.QuadPart - qpc_prev.QuadPart) * 1000.0 / qpc_freq.QuadPart;
        qpc_prev = qpc_now;

        /* localize any large one-time commit step to its exact frame */
        GetProcessMemoryInfo(GetCurrentProcess(), &mem_frame, sizeof(mem_frame));
        if (mem_prev_pagefile && mem_frame.PagefileUsage > mem_prev_pagefile + 64 * 1024 * 1024)
            printf("commit step at frame %u: %.1f -> %.1f MB pagefile\n", frame,
                   mem_mb(mem_prev_pagefile), mem_mb(mem_frame.PagefileUsage));
        mem_prev_pagefile = mem_frame.PagefileUsage;

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
            DispatchMessageW(&message);
    }

    GetProcessMemoryInfo(GetCurrentProcess(), &mem_end, sizeof(mem_end));

    /* depth-proof readback: anchor corner must be red, not blue */
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging,
                                     (ID3D11Resource *)backbuffer);
    result =
        ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result))
        return 15;
    anchor_x = (unsigned int)((-0.9f + 1.0f) * 0.5f * WIDTH);
    anchor_y = (unsigned int)((1.0f - (-0.85f)) * 0.5f * HEIGHT);
    pixel = (const unsigned char *)mapped.pData + anchor_y * mapped.RowPitch + anchor_x * 4;
    printf("anchor (%u,%u): b=%u g=%u r=%u (expected 0 0 255: red wins depth)\n", anchor_x,
           anchor_y, pixel[0], pixel[1], pixel[2]);
    if (pixel[2] < 250 || pixel[0] > 5 || pixel[1] > 5)
    {
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
        return 16;
    }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    puts("stage: depth anchor verified");

    {
        static double sorted[MEASURED_FRAMES];
        double total = 0.0;

        memcpy(sorted, frame_ms, sizeof(sorted));
        qsort(sorted, MEASURED_FRAMES, sizeof(double), compare_double);
        for (frame = 0; frame < MEASURED_FRAMES; frame++)
            total += frame_ms[frame];
        mean_ms = total / MEASURED_FRAMES;

        printf("frames: %u measured (%u warmup), %u draws + %u cbuffer maps per frame\n",
               MEASURED_FRAMES, WARMUP_FRAMES, OPAQUE_DRAWS + BLENDED_DRAWS + 2,
               OPAQUE_DRAWS + BLENDED_DRAWS + 2);
        printf("first frame (device->present, cold pipelines): %.1f ms\n", first_frame_ms);
        printf("frame time ms: mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f\n", mean_ms,
               sorted[MEASURED_FRAMES / 2], sorted[MEASURED_FRAMES * 95 / 100],
               sorted[MEASURED_FRAMES * 99 / 100], sorted[MEASURED_FRAMES - 1]);
        printf("throughput: %.0f fps mean\n", 1000.0 / mean_ms);
        printf("memory MB: working set %.1f -> %.1f, pagefile %.1f -> %.1f\n",
               mem_mb(mem_start.WorkingSetSize), mem_mb(mem_end.WorkingSetSize),
               mem_mb(mem_start.PagefileUsage), mem_mb(mem_end.PagefileUsage));
        if (mem_end.PagefileUsage > mem_start.PagefileUsage + 64 * 1024 * 1024)
        {
            puts("memory growth exceeds 64 MB over measured window");
            return 17;
        }
    }

    puts("gfx-001 d3d11 scene ok");
    return 0;
}
