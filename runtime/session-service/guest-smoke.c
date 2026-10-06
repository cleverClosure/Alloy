// Author: Timur Isaev
#include <windows.h>

void entry(void)
{
    const char message[] = "ALLOY_SYNTHETIC_ENTRY\n";
    DWORD written = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), message, sizeof(message) - 1, &written, NULL);
    ExitProcess(written == sizeof(message) - 1 ? 0 : 7);
}
