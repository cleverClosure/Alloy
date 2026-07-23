/*
 * Alloy per-process policy guest probe
 *
 * Author: Timur Isaev
 */

#include <windows.h>

#ifndef EXPECTED_PROVIDER_ID
#error EXPECTED_PROVIDER_ID must be defined
#endif

#ifndef EXPECTED_PROVIDER_TEXT
#error EXPECTED_PROVIDER_TEXT must be defined
#endif

#ifndef ROLE_NAME
#error ROLE_NAME must be defined
#endif

__declspec(dllimport) unsigned int alloy_graphics_provider(void);
__declspec(dllimport) const char *alloy_graphics_name(void);

static unsigned int string_length(const char *value)
{
    unsigned int length = 0;

    while (value[length])
        length++;
    return length;
}

static void write_text(const char *value)
{
    DWORD written;

    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), value, string_length(value), &written, NULL);
}

static void clear_memory(void *memory, unsigned int size)
{
    unsigned char *bytes = memory;

    while (size--)
        *bytes++ = 0;
}

static void copy_string(char *destination, const char *source, unsigned int capacity)
{
    unsigned int index;

    for (index = 0; index + 1 < capacity && source[index]; index++)
        destination[index] = source[index];
    destination[index] = 0;
}

static DWORD run_child(const char *name)
{
    PROCESS_INFORMATION process;
    STARTUPINFOA startup;
    char command[MAX_PATH];
    DWORD exit_code = 0xff;

    clear_memory(&process, sizeof(process));
    clear_memory(&startup, sizeof(startup));
    startup.cb = sizeof(startup);
    copy_string(command, name, sizeof(command));
    if (!CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
    {
        write_text("PROBE spawn-failed\n");
        return 0xfe;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return exit_code;
}

void entry(void)
{
    const char *provider = alloy_graphics_name();
    unsigned int provider_id = alloy_graphics_provider();
    DWORD status = 0;

    write_text("PROBE role=" ROLE_NAME " provider=");
    write_text(provider);
    write_text(" id=" EXPECTED_PROVIDER_TEXT "\n");
    if (provider_id != EXPECTED_PROVIDER_ID)
        status = 90;

#ifdef LAUNCH_CHILDREN
    if (!status)
    {
        DWORD game_status = run_child("game.exe");
        DWORD unknown_status = run_child("unknown.exe");

        if (!game_status && !unknown_status)
            write_text("SESSION game=0 unknown=0\n");
        else
        {
            write_text("SESSION child-failure\n");
            status = game_status ? game_status : unknown_status;
        }
    }
#endif
    ExitProcess(status);
}
