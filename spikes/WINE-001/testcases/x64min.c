/* Minimal x86-64 PE with no CRT, no imports, no TLS callbacks.
 * Author: Tim Isaev
 * The canonical gate-3 guest: the first x64 instruction is the entry point,
 * so the loader must reach it via BeginSimulation. Never expected to run. */
int __stdcall entry(void *peb)
{
    (void)peb;
    return 42;
}
