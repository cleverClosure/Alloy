/*
 * Alloy policy-routing marker provider
 *
 * Author: Timur Isaev
 */

#include <windows.h>

#ifndef PROVIDER_ID
#error PROVIDER_ID must be defined
#endif

#ifndef PROVIDER_NAME
#error PROVIDER_NAME must be defined
#endif

BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance;
    (void)reason;
    (void)reserved;
    return TRUE;
}

__declspec(dllexport) unsigned int alloy_graphics_provider(void)
{
    return PROVIDER_ID;
}

__declspec(dllexport) const char *alloy_graphics_name(void)
{
    return PROVIDER_NAME;
}
