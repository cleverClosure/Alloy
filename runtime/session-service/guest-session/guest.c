// Author: Timur Isaev
#include "observations.h"

__declspec(dllimport) const char *alloy_graphics_name(void);
__declspec(dllimport) BOOL alloy_graphics_import_valid(void);

#ifdef CHILD_NAME
static HANDLE child(void)
{
    STARTUPINFOA startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!CreateProcessA("G:\\" CHILD_NAME ".exe", NULL, NULL, NULL, TRUE, 0, NULL, NULL, &startup,
                        &process))
        ExitProcess(20);
    CloseHandle(process.hThread);
    return process.hProcess;
}
#endif

#ifdef WRITE_SAVE
static void save(void)
{
    static const char value[] = "Alloy session service save proof v1\n";
    DWORD written = 0;
    HANDLE file = CreateFileA("S:\\saves\\session-proof.bin", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);
    if (file == INVALID_HANDLE_VALUE ||
        !WriteFile(file, value, sizeof(value) - 1, &written, NULL) ||
        written != sizeof(value) - 1 || !FlushFileBuffers(file))
        ExitProcess(21);
    CloseHandle(file);
    text("SAVE role=game durable=1\n");
}
#endif

#ifdef PROBE_RESTRICTION
static void restriction(void)
{
    BOOL expected = exists("G:\\allow-blocked");
    HMODULE module = LoadLibraryA("alloyblocked.dll");
    text(module ? "RESTRICTION allowed=1\n" : "RESTRICTION allowed=0\n");
    if ((module != NULL) != expected)
        ExitProcess(22);
    if (module)
        FreeLibrary(module);
}
#endif

void entry(void)
{
    char provider[MAX_PATH], expected[MAX_PATH];
    ULONGLONG deadline = GetTickCount64() + 120000;
    BOOL ignore_stop = exists("G:\\ignore-stop");
    observe("GUEST", ROLE_NAME);
    lstrcpyA(expected, "C:\\alloy\\providers\\");
    lstrcatA(expected, ROLE_NAME);
    lstrcatA(expected, "\\alloygraphics.dll");
    if (!alloy_graphics_import_valid() || !policy_is_current(ROLE_NAME, EXPECT_FEX) ||
        lstrcmpA(alloy_graphics_name(), ROLE_NAME) ||
        !GetModuleFileNameA(GetModuleHandleA("alloygraphics.dll"), provider, sizeof(provider)) ||
        lstrcmpiA(provider, expected))
        ExitProcess(23);
    text("POLICY role=" ROLE_NAME " import=1 entry=1 provider=1\n");
#ifdef WRITE_SAVE
    save();
#endif
#ifdef PROBE_RESTRICTION
    restriction();
#endif
#ifdef CHILD_NAME
    HANDLE process = child();
#endif
    text("READY role=" ROLE_NAME "\n");
    while (ignore_stop || !exists("T:\\stop"))
    {
        if (GetTickCount64() >= deadline)
            ExitProcess(24);
#ifdef CHILD_NAME
        if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0)
        {
            if (!ignore_stop && exists("T:\\stop"))
                break;
            ExitProcess(25);
        }
#endif
        Sleep(25);
    }
#ifdef CHILD_NAME
    DWORD status = 26;
    if (WaitForSingleObject(process, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeProcess(process, &status))
        ExitProcess(27);
    CloseHandle(process);
    if (status)
        ExitProcess(status);
#endif
    text("STOP role=" ROLE_NAME " cooperative=1\n");
    ExitProcess(0);
}
