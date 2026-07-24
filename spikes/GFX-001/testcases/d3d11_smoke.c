/*
 * GFX-001 x64 D3D11 first-light smoke test.
 * Author: Timur Isaev
 *
 * Self-verifying: creates a device and swapchain on a real window, clears the
 * backbuffer to a known color, copies it to a staging texture, and checks the
 * mapped bytes on the CPU. Prints the adapter description so the log records
 * which provider actually serviced the call.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <d3d11.h>
#include <stdio.h>
#include <windows.h>

static const float clear_color[4] = {0.25f, 0.5f, 0.75f, 1.0f};

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    return DefWindowProcW(window, message, wparam, lparam);
}

static int color_close(unsigned char value, float expected)
{
    int target = (int)(expected * 255.0f + 0.5f);
    int delta = (int)value - target;

    return delta >= -2 && delta <= 2;
}

int main(void)
{
    WNDCLASSW window_class = {0};
    DXGI_SWAP_CHAIN_DESC swap_desc = {0};
    D3D11_TEXTURE2D_DESC staging_desc;
    D3D11_MAPPED_SUBRESOURCE mapped;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    D3D_FEATURE_LEVEL got_level;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Texture2D *backbuffer = NULL;
    ID3D11Texture2D *staging = NULL;
    ID3D11RenderTargetView *target_view = NULL;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC adapter_desc;
    const unsigned char *pixel;
    HWND window;
    HRESULT result;
    MSG message;

    setvbuf(stdout, NULL, _IONBF, 0);

    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = L"gfx001_d3d11_smoke";
    if (!RegisterClassW(&window_class))
        return 1;
    window = CreateWindowW(window_class.lpszClassName, L"gfx-001 d3d11 smoke",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 320, 240, NULL, NULL,
                           window_class.hInstance, NULL);
    if (!window)
        return 2;
    puts("stage: window created");

    swap_desc.BufferCount = 1;
    swap_desc.BufferDesc.Width = 256;
    swap_desc.BufferDesc.Height = 192;
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
    printf("stage: device created, feature level %04x\n", got_level);

    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &adapter_desc)))
        printf("adapter: %ls vendor=%04x device=%04x\n", adapter_desc.Description,
               adapter_desc.VendorId, adapter_desc.DeviceId);

    result = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&backbuffer);
    if (FAILED(result))
        return 4;
    result = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)backbuffer, NULL,
                                                 &target_view);
    if (FAILED(result))
        return 5;
    puts("stage: render target ready");

    ID3D11DeviceContext_ClearRenderTargetView(context, target_view, clear_color);

    ID3D11Texture2D_GetDesc(backbuffer, &staging_desc);
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;
    result = ID3D11Device_CreateTexture2D(device, &staging_desc, NULL, &staging);
    if (FAILED(result))
        return 6;
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging,
                                     (ID3D11Resource *)backbuffer);

    result =
        ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result))
    {
        printf("map failed: %08lx\n", (unsigned long)result);
        return 7;
    }

    pixel = (const unsigned char *)mapped.pData + 96 * mapped.RowPitch + 128 * 4;
    printf("readback: b=%u g=%u r=%u a=%u (expected %u %u %u 255)\n", pixel[0], pixel[1], pixel[2],
           pixel[3], (unsigned int)(clear_color[2] * 255.0f + 0.5f),
           (unsigned int)(clear_color[1] * 255.0f + 0.5f),
           (unsigned int)(clear_color[0] * 255.0f + 0.5f));
    if (!color_close(pixel[0], clear_color[2]) || !color_close(pixel[1], clear_color[1]) ||
        !color_close(pixel[2], clear_color[0]) || pixel[3] != 255)
    {
        ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
        return 8;
    }
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);
    puts("stage: readback verified");

    result = IDXGISwapChain_Present(swapchain, 0, 0);
    if (FAILED(result))
    {
        printf("present failed: %08lx\n", (unsigned long)result);
        return 9;
    }
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        DispatchMessageW(&message);
    puts("stage: presented");

    puts("gfx-001 d3d11 first light ok");
    return 0;
}
