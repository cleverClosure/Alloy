// Author: Timur Isaev
#include <windows.h>

BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        const char marker[] = "BLOCKED_IMPORT allowed=1\n";
        DWORD written = 0;
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), marker, sizeof(marker) - 1, &written, NULL);
    }
    return TRUE;
}
