/* Author: Timur Isaev */
#include <windows.h>

static void marker(const char *text, DWORD size)
{
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, size, &written, NULL) || written != size)
        ExitProcess(41);
}

#if ROLE < 2
static void spawn(const WCHAR *path)
{
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    if (!CreateProcessW(path, NULL, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
        ExitProcess(42);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
}
#endif

void entry(void)
{
#if ROLE == 0
    spawn(L"G:\\game.exe");
    marker("ALLOY_LAUNCHER_EXIT\n", 20);
    ExitProcess(0);
#elif ROLE == 1
    spawn(L"G:\\brief.exe");
    spawn(L"G:\\unknown.exe");
    marker("ALLOY_GAME_WAIT\n", 16);
#elif ROLE == 2
    marker("ALLOY_UNKNOWN_WAIT\n", 19);
#else
    marker("ALLOY_BRIEF_EXIT\n", 17);
    ExitProcess(0);
#endif
    for (;;)
        Sleep(100);
}
