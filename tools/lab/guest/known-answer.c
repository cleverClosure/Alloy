/* Author: Timur Isaev */
#include <stdio.h>
#include <string.h>
#include <windows.h>

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "clean";
    if (strcmp(mode, "hang") == 0)
    {
        Sleep(60000);
    }
    if (strcmp(mode, "error") == 0)
    {
        return 7;
    }
    unsigned int sum = 0;
    for (unsigned int i = 1; i <= 6; ++i)
    {
        sum += i;
    }
    const unsigned int delta = strcmp(mode, "seeded") == 0 ? 1 : 0;
    printf("{\"answer\":%u,\"sum\":%u}\n", 6 * 7 + delta, sum + delta);
    return 0;
}
