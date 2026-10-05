/* Author: Timur Isaev */
#ifndef ALLOY_POLICY_OBSERVATIONS_H
#define ALLOY_POLICY_OBSERVATIONS_H
#include <windows.h>

static void text(const char *value)
{
    DWORD size = 0, written;
    while (value[size])
        size++;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), value, size, &written, NULL);
}

static void observe(const char *phase, const char *identifier)
{
    char value[2048];
    BOOL fex = GetModuleHandleA("libarm64ecfex.dll") != NULL;
    text(phase);
    text(" id=");
    text(identifier);
    text(" LANG=");
    if (GetEnvironmentVariableA("LANG", value, sizeof(value)))
        text(value);
    else
        text("<absent>");
    text(" cwd=");
    if (GetCurrentDirectoryA(sizeof(value), value))
        text(value);
    text(" fex=");
    text(fex ? "1" : "0");
    text("\n");
}
#endif
