// Author: Timur Isaev
#ifndef ALLOY_SESSION_OBSERVATIONS_H
#define ALLOY_SESSION_OBSERVATIONS_H
#include <windows.h>

static void text(const char *value)
{
    DWORD written = 0;
    DWORD length = (DWORD)lstrlenA(value);
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), value, length, &written, NULL);
}

static BOOL exists(const char *path)
{
    return GetFileAttributesA(path) != INVALID_FILE_ATTRIBUTES;
}

static BOOL policy_is_current(const char *role, BOOL expected_fex)
{
    char language[256], directory[MAX_PATH], expected[MAX_PATH];
    if (!GetEnvironmentVariableA("LANG", language, sizeof(language)) ||
        !GetCurrentDirectoryA(sizeof(directory), directory))
        return FALSE;
    lstrcpyA(expected, "G:\\cwd-");
    lstrcatA(expected, role);
    return !lstrcmpA(language, role) && !lstrcmpiA(directory, expected) &&
           (GetModuleHandleA("libarm64ecfex.dll") != NULL) == expected_fex;
}

static void observe(const char *phase, const char *role)
{
    char line[1024], language[256], directory[MAX_PATH];
    lstrcpyA(language, "<absent>");
    lstrcpyA(directory, "<absent>");
    GetEnvironmentVariableA("LANG", language, sizeof(language));
    GetCurrentDirectoryA(sizeof(directory), directory);
    lstrcpyA(line, phase);
    lstrcatA(line, " id=");
    lstrcatA(line, role);
    lstrcatA(line, " LANG=");
    lstrcatA(line, language);
    lstrcatA(line, " cwd=");
    lstrcatA(line, directory);
    lstrcatA(line, GetModuleHandleA("libarm64ecfex.dll") ? " fex=1\n" : " fex=0\n");
    text(line);
}
#endif
