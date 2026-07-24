/*
 * CPU-001/GFX x64 windowing and GDI smoke test.
 * Author: Timur Isaev
 *
 * Self-verifying: creates a real top-level window, paints the client area
 * red on WM_PAINT, then reads a client pixel back through GDI. Exit 0 only
 * if the window came up and the readback matches.
 */

#include <stdio.h>
#include <windows.h>

static const COLORREF expected_color = RGB(200, 30, 40);
static LONG paint_count;
static LONG verified;

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message)
    {
    case WM_PAINT:
    {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        HBRUSH brush = CreateSolidBrush(expected_color);

        FillRect(dc, &paint.rcPaint, brush);
        DeleteObject(brush);
        EndPaint(window, &paint);
        InterlockedIncrement(&paint_count);
        return 0;
    }
    case WM_USER:
    {
        RECT client;
        HDC dc = GetDC(window);
        COLORREF center, corner;

        if (!GetClientRect(window, &client) || client.right < 64 || client.bottom < 64)
        {
            printf("client rect degenerate: %ldx%ld\n", client.right, client.bottom);
            PostQuitMessage(3);
            return 0;
        }
        center = GetPixel(dc, client.right / 2, client.bottom / 2);
        corner = GetPixel(dc, 4, 4);
        ReleaseDC(window, dc);
        printf("readback: center=%06lx corner=%06lx expected=%06lx paints=%ld\n",
               (unsigned long)center, (unsigned long)corner, (unsigned long)expected_color,
               paint_count);
        if (center == expected_color && corner == expected_color)
        {
            InterlockedExchange(&verified, 1);
            PostQuitMessage(0);
        }
        else
        {
            PostQuitMessage(4);
        }
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(5);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

int main(void)
{
    WNDCLASSW window_class = {0};
    HWND window;
    MSG message;
    DWORD start;

    setvbuf(stdout, NULL, _IONBF, 0);

    window_class.lpfnWndProc = window_proc;
    window_class.hInstance = GetModuleHandleW(NULL);
    window_class.lpszClassName = L"cpu001_win_smoke";
    window_class.hbrBackground = NULL;
    if (!RegisterClassW(&window_class))
        return 1;

    window = CreateWindowW(window_class.lpszClassName, L"cpu-001 win smoke",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 80, 80, 320, 240, NULL, NULL,
                           window_class.hInstance, NULL);
    if (!window)
        return 2;
    printf("window created: %p visible=%d\n", (void *)window, IsWindowVisible(window));

    UpdateWindow(window);
    PostMessageW(window, WM_USER, 0, 0);

    start = GetTickCount();
    while (GetMessageW(&message, NULL, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
        if (GetTickCount() - start > 15000)
        {
            puts("timeout waiting for verification");
            return 6;
        }
    }

    if (verified && paint_count > 0)
    {
        puts("cpu-001 window/GDI smoke ok");
        return 0;
    }
    return (int)message.wParam;
}
