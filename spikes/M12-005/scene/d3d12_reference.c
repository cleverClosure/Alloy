/*
 * M12-005 x64 D3D12 reference scene for the lab-only D3DMetal baseline.
 * Author: Timur Isaev
 *
 * Renders an animated procedural scene through a minimal D3D12 pipeline,
 * captures the final backbuffer through a readback resource, and writes a
 * deterministic bitmap. The program fails if the captured image is nearly
 * uniform, turning "a window appeared" into a machine-checkable render proof.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <d3d12.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#define WIDTH 640
#define HEIGHT 360
#define FRAME_COUNT 120
#define BACKBUFFER_COUNT 2
#define OUTPUT_BITMAP "m12-gptk-reference.bmp"

#define CHECK_HR(stage, expression)                                                                \
    do                                                                                             \
    {                                                                                              \
        HRESULT check_result = (expression);                                                       \
        if (FAILED(check_result))                                                                  \
        {                                                                                          \
            printf("failure: %s: %08lx\n", stage, (unsigned long)check_result);                    \
            return 1;                                                                              \
        }                                                                                          \
    } while (0)

static const char shader_source[] =
    "cbuffer Frame : register(b0)\n"
    "{\n"
    "    float4 params;\n"
    "};\n"
    "struct VSOut\n"
    "{\n"
    "    float4 position : SV_Position;\n"
    "    float2 uv : TEXCOORD0;\n"
    "};\n"
    "VSOut vs_main(uint vertex_id : SV_VertexID)\n"
    "{\n"
    "    float2 positions[3] = {\n"
    "        float2(-1.0, -1.0),\n"
    "        float2(-1.0,  3.0),\n"
    "        float2( 3.0, -1.0)\n"
    "    };\n"
    "    VSOut output;\n"
    "    output.position = float4(positions[vertex_id], 0.0, 1.0);\n"
    "    output.uv = positions[vertex_id] * float2(0.5, -0.5) + 0.5;\n"
    "    return output;\n"
    "}\n"
    "float4 ps_main(VSOut input) : SV_Target\n"
    "{\n"
    "    float2 uv = input.uv;\n"
    "    float2 centered = (uv - 0.5) * float2(params.y, 1.0);\n"
    "    float radius = length(centered);\n"
    "    float angle = atan2(centered.y, centered.x);\n"
    "    float ring = 0.5 + 0.5 * cos(48.0 * radius - params.x * 6.2831853);\n"
    "    float spokes = 0.5 + 0.5 * cos(12.0 * angle + params.x * 3.1415927);\n"
    "    float checker = fmod(floor(uv.x * 12.0) + floor(uv.y * 7.0), 2.0);\n"
    "    float3 gradient = float3(uv.x, uv.y, 1.0 - uv.x * 0.65);\n"
    "    float3 accent = float3(0.08 + ring * 0.18, 0.35 + spokes * 0.35, 0.92);\n"
    "    float vignette = saturate(1.2 - radius * 0.9);\n"
    "    float3 color = lerp(gradient, accent, 0.28 + checker * 0.16) * vignette;\n"
    "    float core = 1.0 - smoothstep(0.15, 0.155, radius);\n"
    "    color = lerp(color, float3(1.0, 0.42, 0.12), core * (0.45 + ring * 0.35));\n"
    "    return float4(saturate(color), 1.0);\n"
    "}\n";

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_CLOSE || message == WM_DESTROY)
    {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

static ID3DBlob *compile_shader(const char *entry, const char *target)
{
    ID3DBlob *shader = NULL;
    ID3DBlob *errors = NULL;
    HRESULT result =
        D3DCompile(shader_source, sizeof(shader_source) - 1, "m12-reference.hlsl", NULL, NULL,
                   entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &shader, &errors);

    if (FAILED(result))
    {
        printf("failure: compile %s: %08lx\n%s\n", entry, (unsigned long)result,
               errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "(no compiler log)");
        return NULL;
    }
    if (errors)
        ID3D10Blob_Release(errors);
    return shader;
}

static HRESULT wait_for_gpu(ID3D12CommandQueue *queue, ID3D12Fence *fence, HANDLE event,
                            UINT64 *value)
{
    HRESULT result;
    DWORD wait_result;

    ++*value;
    result = ID3D12CommandQueue_Signal(queue, fence, *value);
    if (FAILED(result))
        return result;
    if (ID3D12Fence_GetCompletedValue(fence) >= *value)
        return S_OK;

    result = ID3D12Fence_SetEventOnCompletion(fence, *value, event);
    if (FAILED(result))
        return result;
    wait_result = WaitForSingleObject(event, 10000);
    return wait_result == WAIT_OBJECT_0 ? S_OK : HRESULT_FROM_WIN32(ERROR_TIMEOUT);
}

static D3D12_RESOURCE_BARRIER transition(ID3D12Resource *resource, D3D12_RESOURCE_STATES before,
                                         D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER barrier = {0};

    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    return barrier;
}

static int compare_double(const void *left, const void *right)
{
    double a = *(const double *)left;
    double b = *(const double *)right;

    return a < b ? -1 : a > b ? 1 : 0;
}

static double elapsed_ms(LARGE_INTEGER start, LARGE_INTEGER end, LARGE_INTEGER frequency)
{
    return (double)(end.QuadPart - start.QuadPart) * 1000.0 / (double)frequency.QuadPart;
}

static int write_bitmap(const unsigned char *pixels, UINT row_pitch, uint64_t *digest_out,
                        size_t *changed_out)
{
    BITMAPFILEHEADER file_header = {0};
    BITMAPINFOHEADER info_header = {0};
    unsigned char row[WIDTH * 3];
    const unsigned char *first = pixels;
    uint64_t digest = UINT64_C(1469598103934665603);
    size_t changed = 0;
    FILE *file;
    unsigned int x, y;

    file_header.bfType = 0x4d42;
    file_header.bfOffBits = sizeof(file_header) + sizeof(info_header);
    file_header.bfSize = file_header.bfOffBits + sizeof(row) * HEIGHT;
    info_header.biSize = sizeof(info_header);
    info_header.biWidth = WIDTH;
    info_header.biHeight = -HEIGHT;
    info_header.biPlanes = 1;
    info_header.biBitCount = 24;
    info_header.biCompression = BI_RGB;
    info_header.biSizeImage = sizeof(row) * HEIGHT;

    file = fopen(OUTPUT_BITMAP, "wb");
    if (!file)
    {
        puts("failure: could not create reference bitmap");
        return 0;
    }

    if (fwrite(&file_header, sizeof(file_header), 1, file) != 1 ||
        fwrite(&info_header, sizeof(info_header), 1, file) != 1)
    {
        fclose(file);
        puts("failure: could not write bitmap header");
        return 0;
    }

    for (y = 0; y < HEIGHT; ++y)
    {
        const unsigned char *source = pixels + y * row_pitch;

        for (x = 0; x < WIDTH; ++x)
        {
            const unsigned char *pixel = source + x * 4;

            row[x * 3 + 0] = pixel[2];
            row[x * 3 + 1] = pixel[1];
            row[x * 3 + 2] = pixel[0];
            if (pixel[0] != first[0] || pixel[1] != first[1] || pixel[2] != first[2])
                ++changed;
            digest ^= pixel[0];
            digest *= UINT64_C(1099511628211);
            digest ^= pixel[1];
            digest *= UINT64_C(1099511628211);
            digest ^= pixel[2];
            digest *= UINT64_C(1099511628211);
        }
        if (fwrite(row, sizeof(row), 1, file) != 1)
        {
            fclose(file);
            puts("failure: could not write bitmap pixels");
            return 0;
        }
    }

    fclose(file);
    *digest_out = digest;
    *changed_out = changed;
    return 1;
}

int main(void)
{
    WNDCLASSW window_class = {0};
    DXGI_SWAP_CHAIN_DESC1 swap_desc = {0};
    D3D12_COMMAND_QUEUE_DESC queue_desc = {0};
    D3D12_DESCRIPTOR_HEAP_DESC rtv_heap_desc = {0};
    D3D12_ROOT_PARAMETER root_parameter = {0};
    D3D12_ROOT_SIGNATURE_DESC root_desc = {0};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pipeline_desc = {0};
    D3D12_VIEWPORT viewport = {0.0f, 0.0f, (float)WIDTH, (float)HEIGHT, 0.0f, 1.0f};
    D3D12_RECT scissor = {0, 0, WIDTH, HEIGHT};
    D3D12_CPU_DESCRIPTOR_HANDLE rtv_start;
    D3D12_HEAP_PROPERTIES readback_heap = {0};
    D3D12_RESOURCE_DESC backbuffer_desc;
    D3D12_RESOURCE_DESC readback_desc = {0};
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT readback_layout;
    D3D12_TEXTURE_COPY_LOCATION copy_source = {0};
    D3D12_TEXTURE_COPY_LOCATION copy_destination = {0};
    D3D12_RANGE read_range;
    ID3D12Device *device = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *command_list = NULL;
    ID3D12DescriptorHeap *rtv_heap = NULL;
    ID3D12RootSignature *root_signature = NULL;
    ID3D12PipelineState *pipeline = NULL;
    ID3D12Resource *backbuffers[BACKBUFFER_COUNT] = {NULL, NULL};
    ID3D12Resource *readback = NULL;
    ID3D12Fence *fence = NULL;
    IDXGIFactory4 *factory = NULL;
    IDXGISwapChain1 *swapchain1 = NULL;
    IDXGISwapChain3 *swapchain = NULL;
    ID3DBlob *vertex_shader = NULL;
    ID3DBlob *pixel_shader = NULL;
    ID3DBlob *serialized_root = NULL;
    ID3DBlob *root_errors = NULL;
    ID3D12CommandList *submitted_lists[1];
    D3D12_CPU_DESCRIPTOR_HANDLE render_target;
    D3D12_RESOURCE_BARRIER barriers[2];
    LARGE_INTEGER frequency, setup_start, setup_end, frame_start, frame_end;
    double frame_times[FRAME_COUNT];
    double sorted_times[FRAME_COUNT - 1];
    double warm_mean = 0.0;
    UINT descriptor_size;
    UINT64 row_size, readback_size;
    UINT row_count;
    UINT64 fence_value = 0;
    HANDLE fence_event;
    HWND window;
    MSG message;
    uint64_t digest;
    size_t changed_pixels;
    unsigned char *mapped_pixels;
    unsigned int frame, index;

    setvbuf(stdout, NULL, _IONBF, 0);
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&setup_start);

    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = L"alloy_m12_d3d12_reference";
    if (!RegisterClassW(&window_class))
    {
        puts("failure: RegisterClassW");
        return 1;
    }
    window = CreateWindowW(window_class.lpszClassName, L"Alloy M12 D3D12 Reference",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, WIDTH, HEIGHT, NULL, NULL,
                           window_class.hInstance, NULL);
    if (!window)
    {
        puts("failure: CreateWindowW");
        return 1;
    }
    puts("stage: window");

    CHECK_HR("CreateDXGIFactory1", CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory));
    CHECK_HR("D3D12CreateDevice",
             D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device));

    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    CHECK_HR("CreateCommandQueue",
             ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue,
                                             (void **)&queue));

    swap_desc.Width = WIDTH;
    swap_desc.Height = HEIGHT;
    swap_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.BufferCount = BACKBUFFER_COUNT;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    swap_desc.Scaling = DXGI_SCALING_STRETCH;
    swap_desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    CHECK_HR("CreateSwapChainForHwnd",
             IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, window, &swap_desc,
                                                  NULL, NULL, &swapchain1));
    CHECK_HR("swap-chain query",
             IDXGISwapChain1_QueryInterface(swapchain1, &IID_IDXGISwapChain3, (void **)&swapchain));

    rtv_heap_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtv_heap_desc.NumDescriptors = BACKBUFFER_COUNT;
    CHECK_HR("CreateDescriptorHeap",
             ID3D12Device_CreateDescriptorHeap(device, &rtv_heap_desc, &IID_ID3D12DescriptorHeap,
                                               (void **)&rtv_heap));
    rtv_heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(rtv_heap, &rtv_start);
    descriptor_size =
        ID3D12Device_GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

    for (index = 0; index < BACKBUFFER_COUNT; ++index)
    {
        D3D12_CPU_DESCRIPTOR_HANDLE handle = rtv_start;

        handle.ptr += (SIZE_T)index * descriptor_size;
        CHECK_HR("GetBuffer", IDXGISwapChain3_GetBuffer(swapchain, index, &IID_ID3D12Resource,
                                                        (void **)&backbuffers[index]));
        ID3D12Device_CreateRenderTargetView(device, backbuffers[index], NULL, handle);
    }

    CHECK_HR("CreateCommandAllocator",
             ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                 &IID_ID3D12CommandAllocator, (void **)&allocator));

    root_parameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    root_parameter.Constants.ShaderRegister = 0;
    root_parameter.Constants.RegisterSpace = 0;
    root_parameter.Constants.Num32BitValues = 4;
    root_parameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    root_desc.NumParameters = 1;
    root_desc.pParameters = &root_parameter;
    root_desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    CHECK_HR("D3D12SerializeRootSignature",
             D3D12SerializeRootSignature(&root_desc, D3D_ROOT_SIGNATURE_VERSION_1, &serialized_root,
                                         &root_errors));
    CHECK_HR("CreateRootSignature", ID3D12Device_CreateRootSignature(
                                        device, 0, ID3D10Blob_GetBufferPointer(serialized_root),
                                        ID3D10Blob_GetBufferSize(serialized_root),
                                        &IID_ID3D12RootSignature, (void **)&root_signature));

    vertex_shader = compile_shader("vs_main", "vs_5_1");
    pixel_shader = compile_shader("ps_main", "ps_5_1");
    if (!vertex_shader || !pixel_shader)
        return 1;

    pipeline_desc.pRootSignature = root_signature;
    pipeline_desc.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vertex_shader);
    pipeline_desc.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vertex_shader);
    pipeline_desc.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(pixel_shader);
    pipeline_desc.PS.BytecodeLength = ID3D10Blob_GetBufferSize(pixel_shader);
    pipeline_desc.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_ONE;
    pipeline_desc.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_ZERO;
    pipeline_desc.BlendState.RenderTarget[0].BlendOp = D3D12_BLEND_OP_ADD;
    pipeline_desc.BlendState.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE;
    pipeline_desc.BlendState.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ZERO;
    pipeline_desc.BlendState.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_ADD;
    pipeline_desc.BlendState.RenderTarget[0].LogicOp = D3D12_LOGIC_OP_NOOP;
    pipeline_desc.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pipeline_desc.SampleMask = UINT_MAX;
    pipeline_desc.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pipeline_desc.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pipeline_desc.RasterizerState.DepthClipEnable = TRUE;
    pipeline_desc.DepthStencilState.DepthEnable = FALSE;
    pipeline_desc.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    pipeline_desc.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    pipeline_desc.DepthStencilState.StencilEnable = FALSE;
    pipeline_desc.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pipeline_desc.NumRenderTargets = 1;
    pipeline_desc.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pipeline_desc.SampleDesc.Count = 1;
    CHECK_HR("CreateGraphicsPipelineState",
             ID3D12Device_CreateGraphicsPipelineState(
                 device, &pipeline_desc, &IID_ID3D12PipelineState, (void **)&pipeline));
    CHECK_HR("CreateCommandList",
             ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator,
                                            pipeline, &IID_ID3D12GraphicsCommandList,
                                            (void **)&command_list));
    CHECK_HR("initial Close", ID3D12GraphicsCommandList_Close(command_list));

    backbuffers[0]->lpVtbl->GetDesc(backbuffers[0], &backbuffer_desc);
    ID3D12Device_GetCopyableFootprints(device, &backbuffer_desc, 0, 1, 0, &readback_layout,
                                       &row_count, &row_size, &readback_size);
    readback_heap.Type = D3D12_HEAP_TYPE_READBACK;
    readback_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    readback_desc.Width = readback_size;
    readback_desc.Height = 1;
    readback_desc.DepthOrArraySize = 1;
    readback_desc.MipLevels = 1;
    readback_desc.SampleDesc.Count = 1;
    readback_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    CHECK_HR("CreateCommittedResource(readback)",
             ID3D12Device_CreateCommittedResource(device, &readback_heap, D3D12_HEAP_FLAG_NONE,
                                                  &readback_desc, D3D12_RESOURCE_STATE_COPY_DEST,
                                                  NULL, &IID_ID3D12Resource, (void **)&readback));

    CHECK_HR("CreateFence", ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE,
                                                     &IID_ID3D12Fence, (void **)&fence));
    fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!fence_event)
    {
        puts("failure: CreateEventW");
        return 1;
    }
    QueryPerformanceCounter(&setup_end);
    puts("stage: D3D12 pipeline");

    for (frame = 0; frame < FRAME_COUNT; ++frame)
    {
        float parameters[4] = {
            (float)frame / (float)(FRAME_COUNT - 1),
            (float)WIDTH / (float)HEIGHT,
            (float)WIDTH,
            (float)HEIGHT,
        };
        const float clear[4] = {0.015f, 0.02f, 0.035f, 1.0f};
        WINBOOL capture = frame + 1 == FRAME_COUNT;

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
            if (message.message == WM_QUIT)
            {
                puts("failure: window closed before capture");
                return 1;
            }
        }

        QueryPerformanceCounter(&frame_start);
        index = IDXGISwapChain3_GetCurrentBackBufferIndex(swapchain);
        render_target = rtv_start;
        render_target.ptr += (SIZE_T)index * descriptor_size;

        CHECK_HR("allocator Reset", ID3D12CommandAllocator_Reset(allocator));
        CHECK_HR("command-list Reset",
                 ID3D12GraphicsCommandList_Reset(command_list, allocator, pipeline));
        barriers[0] = transition(backbuffers[index], D3D12_RESOURCE_STATE_PRESENT,
                                 D3D12_RESOURCE_STATE_RENDER_TARGET);
        ID3D12GraphicsCommandList_ResourceBarrier(command_list, 1, barriers);
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(command_list, root_signature);
        ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(command_list, 0, 4, parameters, 0);
        ID3D12GraphicsCommandList_RSSetViewports(command_list, 1, &viewport);
        ID3D12GraphicsCommandList_RSSetScissorRects(command_list, 1, &scissor);
        ID3D12GraphicsCommandList_OMSetRenderTargets(command_list, 1, &render_target, TRUE, NULL);
        ID3D12GraphicsCommandList_ClearRenderTargetView(command_list, render_target, clear, 0,
                                                        NULL);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology(command_list,
                                                         D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D12GraphicsCommandList_DrawInstanced(command_list, 3, 1, 0, 0);

        if (capture)
        {
            barriers[0] = transition(backbuffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET,
                                     D3D12_RESOURCE_STATE_COPY_SOURCE);
            ID3D12GraphicsCommandList_ResourceBarrier(command_list, 1, barriers);
            copy_source.pResource = backbuffers[index];
            copy_source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            copy_source.SubresourceIndex = 0;
            copy_destination.pResource = readback;
            copy_destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            copy_destination.PlacedFootprint = readback_layout;
            ID3D12GraphicsCommandList_CopyTextureRegion(command_list, &copy_destination, 0, 0, 0,
                                                        &copy_source, NULL);
            barriers[0] = transition(backbuffers[index], D3D12_RESOURCE_STATE_COPY_SOURCE,
                                     D3D12_RESOURCE_STATE_PRESENT);
        }
        else
        {
            barriers[0] = transition(backbuffers[index], D3D12_RESOURCE_STATE_RENDER_TARGET,
                                     D3D12_RESOURCE_STATE_PRESENT);
        }
        ID3D12GraphicsCommandList_ResourceBarrier(command_list, 1, barriers);
        CHECK_HR("command-list Close", ID3D12GraphicsCommandList_Close(command_list));
        submitted_lists[0] = (ID3D12CommandList *)command_list;
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, submitted_lists);
        CHECK_HR("Present", IDXGISwapChain3_Present(swapchain, 0, 0));
        CHECK_HR("GPU fence", wait_for_gpu(queue, fence, fence_event, &fence_value));
        QueryPerformanceCounter(&frame_end);
        frame_times[frame] = elapsed_ms(frame_start, frame_end, frequency);
    }

    read_range.Begin = 0;
    read_range.End = (SIZE_T)readback_size;
    CHECK_HR("readback Map", ID3D12Resource_Map(readback, 0, &read_range, (void **)&mapped_pixels));
    if (!write_bitmap(mapped_pixels, readback_layout.Footprint.RowPitch, &digest, &changed_pixels))
        return 1;
    read_range.Begin = 0;
    read_range.End = 0;
    ID3D12Resource_Unmap(readback, 0, &read_range);

    if (changed_pixels < (size_t)(WIDTH * HEIGHT * 3 / 4))
    {
        printf("failure: image diversity too low: %zu/%u pixels\n", changed_pixels, WIDTH * HEIGHT);
        return 1;
    }

    memcpy(sorted_times, frame_times + 1, sizeof(sorted_times));
    qsort(sorted_times, FRAME_COUNT - 1, sizeof(sorted_times[0]), compare_double);
    for (frame = 1; frame < FRAME_COUNT; ++frame)
        warm_mean += frame_times[frame];
    warm_mean /= FRAME_COUNT - 1;

    printf("metric: setup_ms=%.3f\n", elapsed_ms(setup_start, setup_end, frequency));
    printf("metric: first_frame_ms=%.3f\n", frame_times[0]);
    printf("metric: warm_mean_ms=%.3f\n", warm_mean);
    printf("metric: warm_p50_ms=%.3f\n", sorted_times[(FRAME_COUNT - 1) / 2]);
    printf("metric: warm_p95_ms=%.3f\n", sorted_times[((FRAME_COUNT - 1) * 95) / 100]);
    printf("metric: changed_pixels=%zu/%u\n", changed_pixels, WIDTH * HEIGHT);
    printf("metric: image_fnv1a64=%016llx\n", (unsigned long long)digest);
    printf("artifact: %s\n", OUTPUT_BITMAP);
    puts("status: PASS");

    CloseHandle(fence_event);
    DestroyWindow(window);
    return 0;
}
