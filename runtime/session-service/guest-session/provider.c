// Author: Timur Isaev
#include "observations.h"

static BOOL valid_at_import;

__declspec(dllexport) const char *alloy_graphics_name(void)
{
    return ROLE_NAME;
}

__declspec(dllexport) BOOL alloy_graphics_import_valid(void)
{
    return valid_at_import;
}

BOOL WINAPI DllMainCRTStartup(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        valid_at_import = policy_is_current(ROLE_NAME, EXPECT_FEX);
        observe("IMPORT", ROLE_NAME);
        text("RUNTIME role=" ROLE_NAME " variant=" RUNTIME_VARIANT "\n");
    }
    return TRUE;
}
