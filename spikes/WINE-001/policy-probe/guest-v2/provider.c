/* Author: Timur Isaev */
#include "observations.h"

__declspec(dllexport) const char *alloy_graphics_name(void)
{
    return PROVIDER_NAME;
}

BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
        observe("IMPORT", PROVIDER_NAME);
    return TRUE;
}
