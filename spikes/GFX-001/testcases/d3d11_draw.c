/*
 * GFX-001 x64 D3D11 gate-3 draw test: solid triangle + textured quad.
 * Author: Timur Isaev
 *
 * Exercises the full shader path (runtime HLSL -> DXBC via d3dcompiler,
 * then DXMT's DXBC -> AIR translation) plus vertex buffers, input layout,
 * viewport, texture upload, and per-pixel readback verification.
 *
 * Stage A clears the backbuffer and draws a green triangle over the center;
 * readback checks one pixel inside and one outside the triangle.
 * Stage B draws a fullscreen quad whose pixel shader Loads a 2x2 texture by
 * pixel parity, so every screen pixel proves both texel upload and integer
 * addressing; readback checks the four parities.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <windows.h>

#define WIDTH 256
#define HEIGHT 192

static const float clear_color[4] = {0.25f, 0.5f, 0.75f, 1.0f};

static const char shader_source[] = "struct vs_out { float4 pos : SV_Position; };\n"
                                    "vs_out vs_main(float4 pos : POSITION)\n"
                                    "{\n"
                                    "    vs_out o;\n"
                                    "    o.pos = pos;\n"
                                    "    return o;\n"
                                    "}\n"
                                    "float4 ps_solid(vs_out i) : SV_Target\n"
                                    "{\n"
                                    "    return float4(0.0, 1.0, 0.0, 1.0);\n"
                                    "}\n"
                                    "Texture2D tex : register(t0);\n"
                                    "float4 ps_tex(vs_out i) : SV_Target\n"
                                    "{\n"
                                    "    int2 p = int2(i.pos.xy);\n"
                                    "    return tex.Load(int3(p.x & 1, p.y & 1, 0));\n"
                                    "}\n";

struct vec4
{
    float x, y, z, w;
};

static const struct vec4 triangle_verts[] = {
    {-0.5f, -0.5f, 0.0f, 1.0f},
    {0.0f, 0.5f, 0.0f, 1.0f},
    {0.5f, -0.5f, 0.0f, 1.0f},
};

static const struct vec4 quad_verts[] = {
    {-1.0f, -1.0f, 0.0f, 1.0f},
    {-1.0f, 1.0f, 0.0f, 1.0f},
    {1.0f, -1.0f, 0.0f, 1.0f},
    {1.0f, 1.0f, 0.0f, 1.0f},
};

/* 2x2 BGRA texels: (0,0) red, (1,0) green, (0,1) blue, (1,1) white */
static const unsigned char texels[2][8] = {
    {0, 0, 255, 255, 0, 255, 0, 255},
    {255, 0, 0, 255, 255, 255, 255, 255},
};

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(window, message, wparam, lparam);
}

static int color_is(const unsigned char *pixel, unsigned char b, unsigned char g, unsigned char r)
{
    int db = (int)pixel[0] - b, dg = (int)pixel[1] - g, dr = (int)pixel[2] - r;

    return db >= -2 && db <= 2 && dg >= -2 && dg <= 2 && dr >= -2 && dr <= 2 && pixel[3] == 255;
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
    printf("stage: compiled %s (%lu bytes DXBC)\n", entry,
           (unsigned long)ID3D10Blob_GetBufferSize(blob));
    return blob;
}

static const unsigned char *pixel_at(const D3D11_MAPPED_SUBRESOURCE *mapped, unsigned int x,
                                     unsigned int y)
{
    return (const unsigned char *)mapped->pData + y * mapped->RowPitch + x * 4;
}

int main(void)
{
    WNDCLASSW window_class = {0};
    DXGI_SWAP_CHAIN_DESC swap_desc = {0};
    D3D11_BUFFER_DESC buffer_desc = {0};
    D3D11_SUBRESOURCE_DATA init_data = {0};
    D3D11_TEXTURE2D_DESC tex_desc = {0};
    D3D11_TEXTURE2D_DESC staging_desc;
    D3D11_MAPPED_SUBRESOURCE mapped;
    D3D11_VIEWPORT viewport = {0.0f, 0.0f, (float)WIDTH, (float)HEIGHT, 0.0f, 1.0f};
    D3D11_INPUT_ELEMENT_DESC layout_desc = {
        "POSITION", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0};
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    D3D_FEATURE_LEVEL got_level;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL;
    ID3D11Texture2D *staging = NULL;
    ID3D11Texture2D *texture = NULL;
    ID3D11RenderTargetView *target_view = NULL;
    ID3D11ShaderResourceView *texture_view = NULL;
    ID3D11VertexShader *vertex_shader = NULL;
    ID3D11PixelShader *solid_shader = NULL;
    ID3D11PixelShader *tex_shader = NULL;
    ID3D11InputLayout *input_layout = NULL;
    ID3D11Buffer *triangle_buffer = NULL;
    ID3D11Buffer *quad_buffer = NULL;
    ID3DBlob *vs_blob, *ps_solid_blob, *ps_tex_blob;
    UINT stride = sizeof(struct vec4), offset = 0;
    const unsigned char *pixel;
    HWND window;
    HRESULT result;
    MSG message;

    setvbuf(stdout, NULL, _IONBF, 0);

    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = L"gfx001_d3d11_draw";
    if (!RegisterClassW(&window_class))
        return 1;
    window = CreateWindowW(window_class.lpszClassName, L"gfx-001 d3d11 draw",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 320, 240, NULL, NULL,
                           window_class.hInstance, NULL);
    if (!window)
        return 2;
    puts("stage: window created");

    swap_desc.BufferCount = 1;
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
    if (!(ps_solid_blob = compile("ps_solid", "ps_5_0")))
        return 5;
    if (!(ps_tex_blob = compile("ps_tex", "ps_5_0")))
        return 6;

    result =
        ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vs_blob),
                                        ID3D10Blob_GetBufferSize(vs_blob), NULL, &vertex_shader);
    if (FAILED(result))
    {
        printf("create vs failed: %08lx\n", (unsigned long)result);
        return 7;
    }
    result = ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_solid_blob),
                                            ID3D10Blob_GetBufferSize(ps_solid_blob), NULL,
                                            &solid_shader);
    if (FAILED(result))
    {
        printf("create ps_solid failed: %08lx\n", (unsigned long)result);
        return 7;
    }
    result =
        ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(ps_tex_blob),
                                       ID3D10Blob_GetBufferSize(ps_tex_blob), NULL, &tex_shader);
    if (FAILED(result))
    {
        printf("create ps_tex failed: %08lx\n", (unsigned long)result);
        return 7;
    }
    result = ID3D11Device_CreateInputLayout(device, &layout_desc, 1,
                                            ID3D10Blob_GetBufferPointer(vs_blob),
                                            ID3D10Blob_GetBufferSize(vs_blob), &input_layout);
    if (FAILED(result))
    {
        printf("create input layout failed: %08lx\n", (unsigned long)result);
        return 8;
    }
    puts("stage: shaders and layout ready");

    buffer_desc.ByteWidth = sizeof(triangle_verts);
    buffer_desc.Usage = D3D11_USAGE_IMMUTABLE;
    buffer_desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    init_data.pSysMem = triangle_verts;
    result = ID3D11Device_CreateBuffer(device, &buffer_desc, &init_data, &triangle_buffer);
    if (FAILED(result))
        return 9;
    buffer_desc.ByteWidth = sizeof(quad_verts);
    init_data.pSysMem = quad_verts;
    result = ID3D11Device_CreateBuffer(device, &buffer_desc, &init_data, &quad_buffer);
    if (FAILED(result))
        return 9;

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
    {
        printf("create texture failed: %08lx\n", (unsigned long)result);
        return 10;
    }
    result = ID3D11Device_CreateShaderResourceView(device, (ID3D11Resource *)texture, NULL,
                                                   &texture_view);
    if (FAILED(result))
        return 10;
    puts("stage: buffers and texture ready");

    result = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    if (FAILED(result))
        return 11;
    result = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL,
                                                 &target_view);
    if (FAILED(result))
        return 11;

    ID3D11Texture2D_GetDesc(backbuffer, &staging_desc);
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;
    result = ID3D11Device_CreateTexture2D(device, &staging_desc, NULL, &staging);
    if (FAILED(result))
        return 11;

    /* stage A: solid triangle */
    ID3D11DeviceContext_ClearRenderTargetView(context, target_view, clear_color);
    ID3D11DeviceContext_OMSetRenderTargets(context, 1, &target_view, NULL);
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_IASetInputLayout(context, input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetVertexBuffers(context, 0, 1, &triangle_buffer, &stride, &offset);
    ID3D11DeviceContext_VSSetShader(context, vertex_shader, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, solid_shader, NULL, 0);
    ID3D11DeviceContext_Draw(context, 3, 0);

    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging,
                                     (ID3D11Resource *)backbuffer);
    result =
        ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result))
    {
        printf("map failed: %08lx\n", (unsigned long)result);
        return 12;
    }
    pixel = pixel_at(&mapped, WIDTH / 2, HEIGHT / 2);
    printf("triangle inside:  b=%u g=%u r=%u a=%u (expected 0 255 0 255)\n", pixel[0], pixel[1],
           pixel[2], pixel[3]);
    if (!color_is(pixel, 0, 255, 0))
    {
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
        return 13;
    }
    pixel = pixel_at(&mapped, 8, 8);
    printf("triangle outside: b=%u g=%u r=%u a=%u (expected 191 128 64 255)\n", pixel[0], pixel[1],
           pixel[2], pixel[3]);
    if (!color_is(pixel, 191, 128, 64))
    {
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
        return 13;
    }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    puts("stage: triangle verified");

    /* stage B: parity-textured fullscreen quad */
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    ID3D11DeviceContext_IASetVertexBuffers(context, 0, 1, &quad_buffer, &stride, &offset);
    ID3D11DeviceContext_PSSetShader(context, tex_shader, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(context, 0, 1, &texture_view);
    ID3D11DeviceContext_Draw(context, 4, 0);

    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging,
                                     (ID3D11Resource *)backbuffer);
    result =
        ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result))
        return 12;
    pixel = pixel_at(&mapped, 100, 100);
    printf("texel (0,0): b=%u g=%u r=%u (expected 0 0 255)\n", pixel[0], pixel[1], pixel[2]);
    if (!color_is(pixel, 0, 0, 255))
        goto tex_fail;
    pixel = pixel_at(&mapped, 101, 100);
    printf("texel (1,0): b=%u g=%u r=%u (expected 0 255 0)\n", pixel[0], pixel[1], pixel[2]);
    if (!color_is(pixel, 0, 255, 0))
        goto tex_fail;
    pixel = pixel_at(&mapped, 100, 101);
    printf("texel (0,1): b=%u g=%u r=%u (expected 255 0 0)\n", pixel[0], pixel[1], pixel[2]);
    if (!color_is(pixel, 255, 0, 0))
        goto tex_fail;
    pixel = pixel_at(&mapped, 101, 101);
    printf("texel (1,1): b=%u g=%u r=%u (expected 255 255 255)\n", pixel[0], pixel[1], pixel[2]);
    if (!color_is(pixel, 255, 255, 255))
        goto tex_fail;
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    puts("stage: texture verified");

    result = IDXGISwapChain_Present(swapchain, 0, 0);
    if (FAILED(result))
        return 15;
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        DispatchMessageW(&message);

    puts("gfx-001 d3d11 draw ok");
    return 0;

tex_fail:
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    return 14;
}
