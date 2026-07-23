/* Minimal x86-64 console PE for SPIKE-WINE-001 gate 3.
 * Author: Timur Isaev
 * Never expected to execute under the stub emulator — it only has to load. */
#include <stdio.h>

int main(void)
{
    printf("hello from x64 guest\n");
    return 0;
}
