/*
 * GFX-001 launcher/game process split test.
 * Author: Timur Isaev
 *
 * Doc-16 scope item: a guest launcher process spawns the game process,
 * and the D3D11 provider must come up in the child, not the launcher.
 * Spawns d3d11_smoke.exe (the gate-2 first-light guest), waits, and
 * propagates its exit code; exit 0 here means the whole chain -
 * launcher -> CreateProcess -> child device/swapchain/readback - worked.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

int main(void)
{
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    WCHAR command[] = L"d3d11_smoke.exe";
    DWORD child_exit = (DWORD)-1;

    setvbuf(stdout, NULL, _IONBF, 0);
    puts("launcher: spawning d3d11_smoke.exe");

    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
    {
        printf("launcher: CreateProcess failed: %lu\n", (unsigned long)GetLastError());
        return 100;
    }
    if (WaitForSingleObject(process.hProcess, 120000) != WAIT_OBJECT_0)
    {
        puts("launcher: child did not exit within 120s");
        return 101;
    }
    GetExitCodeProcess(process.hProcess, &child_exit);
    printf("launcher: child exit=%lu\n", (unsigned long)child_exit);
    return (int)child_exit;
}
