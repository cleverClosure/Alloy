/* Author: Timur Isaev */
#include "observations.h"

__declspec(dllimport) const char *alloy_graphics_name(void);

#ifdef LAUNCH_CHILDREN
static DWORD child(const char *name)
{
    char executable[2048];
    DWORD length, status = 254;
    STARTUPINFOA startup = {0};
    PROCESS_INFORMATION process = {0};
    length = GetModuleFileNameA(NULL, executable, sizeof(executable));
    if (!length || length >= sizeof(executable))
        return 252;
    while (length && executable[length - 1] != '\\' && executable[length - 1] != '/')
        length--;
    while (*name && length + 1 < sizeof(executable))
        executable[length++] = *name++;
    executable[length] = 0;
    startup.cb = sizeof(startup);
    if (!CreateProcessA(executable, NULL, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
        return 253;
    if (WaitForSingleObject(process.hProcess, 15000) == WAIT_OBJECT_0)
        GetExitCodeProcess(process.hProcess, &status);
    else
        TerminateProcess(process.hProcess, 251);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return status;
}
#endif

void entry(void)
{
    char path[2048];
    observe("GUEST", ROLE_NAME);
    path[0] = 0;
    GetModuleFileNameA(GetModuleHandleA("alloygraphics.dll"), path, sizeof(path));
    text("PROVIDER role=" ROLE_NAME " name=");
    text(alloy_graphics_name());
    text(" path=");
    text(path);
    text("\n");
#ifdef LAUNCH_CHILDREN
    if (child("game.exe") || child("unknown.exe"))
        ExitProcess(250);
    text("SESSION children=0\n");
#endif
    ExitProcess(0);
}
