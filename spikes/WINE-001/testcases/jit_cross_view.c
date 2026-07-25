/*
 * Separate-code/target MAP_JIT regression fixture for Alloy's Wine fork.
 * Author: Tim Isaev
 *
 * Guest x64 code that stores into a *different* MAP_JIT view than the one its
 * own translated code occupies.  Darwin's JIT write switch is per-thread, so
 * without ntdll's translated-store emulation the write and execute positions
 * of that switch alternate forever and the process makes no progress.  This
 * fixture reproduces that livelock on an unfixed runtime.
 *
 * The rejection modes assert with __try/__except rather than by dying.  An
 * "expect the process not to print" oracle cannot tell a correct access
 * violation apart from a livelock, which is the one distinction that matters
 * here: refusing to emulate a store is only useful if the refusal terminates.
 *
 * MUST be built with -Xclang -fasync-exceptions; see build-corpus.sh.
 */

#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*store8_fn)(void *, uint64_t);
typedef void (*store16_fn)(void *, uint64_t);
typedef void (*store32_fn)(void *, uint64_t);
typedef void (*store64_fn)(void *, uint64_t);
typedef void (*store128_fn)(void *, const void *);
typedef uint64_t (*exchange64_fn)(void *, uint64_t);

static const unsigned char store8_code[] = {0x88, 0x11, 0xc3};
static const unsigned char store16_code[] = {0x66, 0x89, 0x11, 0xc3};
static const unsigned char store32_code[] = {0x89, 0x11, 0xc3};
static const unsigned char store64_code[] = {0x48, 0x89, 0x11, 0xc3};
static const unsigned char store128_code[] = {0xf3, 0x0f, 0x6f, 0x02, /* movdqu xmm0,[rdx] */
                                              0xf3, 0x0f, 0x7f, 0x01, /* movdqu [rcx],xmm0 */
                                              0xc3};
static const unsigned char exchange64_code[] = {0x48, 0x89, 0xd0, /* mov rax,rdx */
                                                0x48, 0x87, 0x01, /* xchg [rcx],rax */
                                                0xc3};
static const unsigned char non_temporal128_code[] = {
    0xf3, 0x0f, 0x6f, 0x02, /* movdqu xmm0,[rdx] */
    0x66, 0x0f, 0xe7, 0x01, /* movntdq [rcx],xmm0 */
    0x0f, 0xae, 0xf8,       /* sfence */
    0xc3};

static void *make_jit_function(const unsigned char *code, size_t size)
{
    void *result = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);

    if (!result)
    {
        fprintf(stderr, "VirtualAlloc(code) failed: %lu\n", GetLastError());
        exit(2);
    }
    memcpy(result, code, size);
    if (!FlushInstructionCache(GetCurrentProcess(), result, size))
    {
        fprintf(stderr, "FlushInstructionCache failed: %lu\n", GetLastError());
        exit(3);
    }
    return result;
}

static void *make_target(size_t size, DWORD protect)
{
    void *result = VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT, protect);

    if (!result)
    {
        fprintf(stderr, "VirtualAlloc(target) failed: %lu\n", GetLastError());
        exit(4);
    }
    return result;
}

static int check_bytes(const unsigned char *actual, const unsigned char *expected, size_t size,
                       const char *name)
{
    size_t i;

    if (!memcmp(actual, expected, size))
        return 1;
    fprintf(stderr, "%s mismatch:", name);
    for (i = 0; i < size; i++)
        fprintf(stderr, " %02x/%02x", actual[i], expected[i]);
    fputc('\n', stderr);
    return 0;
}

struct worker_context
{
    store64_fn store;
    unsigned int id;
    int passed;
};

static DWORD WINAPI store_worker(void *opaque)
{
    struct worker_context *context = opaque;
    uint64_t *target = make_target(4096, PAGE_EXECUTE_READWRITE);
    uint64_t expected = 0;
    unsigned int i;

    for (i = 0; i < 64; i++)
    {
        expected = ((uint64_t)context->id << 56) | i;
        context->store(target, expected);
        if (*target != expected)
            break;
    }
    context->passed = i == 64;
    VirtualFree(target, 0, MEM_RELEASE);
    return context->passed ? 0 : 1;
}

static int run_positive(void)
{
    static const unsigned char vector_value[16] = {0x03, 0x14, 0x25, 0x36, 0x47, 0x58, 0x69, 0x7a,
                                                   0x8b, 0x9c, 0xad, 0xbe, 0xcf, 0xd0, 0xe1, 0xf2};
    unsigned char expected[64];
    unsigned char *target = make_target(4096, PAGE_EXECUTE_READWRITE);
    store8_fn store8 = make_jit_function(store8_code, sizeof(store8_code));
    store16_fn store16 = make_jit_function(store16_code, sizeof(store16_code));
    store32_fn store32 = make_jit_function(store32_code, sizeof(store32_code));
    store64_fn store64 = make_jit_function(store64_code, sizeof(store64_code));
    store128_fn store128 = make_jit_function(store128_code, sizeof(store128_code));
    exchange64_fn exchange64 = make_jit_function(exchange64_code, sizeof(exchange64_code));
    struct worker_context contexts[4];
    HANDLE threads[4];
    uint64_t previous;
    unsigned int i;

    memset(target, 0xa5, 64);
    memset(expected, 0xa5, sizeof(expected));

    store8(target, 0x17);
    expected[0] = 0x17;
    store16(target + 2, 0x3928);
    memcpy(expected + 2, "\x28\x39", 2);
    store32(target + 8, 0x7d6c5b4a);
    memcpy(expected + 8, "\x4a\x5b\x6c\x7d", 4);
    store64(target + 16, UINT64_C(0xf1e2d3c4b5a69788));
    memcpy(expected + 16, "\x88\x97\xa6\xb5\xc4\xd3\xe2\xf1", 8);
    store128(target + 32, vector_value);
    memcpy(expected + 32, vector_value, sizeof(vector_value));
    if (!check_bytes(target, expected, sizeof(expected), "scalar/vector stores"))
        return 10;

    store64(target + 48, UINT64_C(0x0123456789abcdef));
    previous = exchange64(target + 48, UINT64_C(0xfedcba9876543210));
    if (previous != UINT64_C(0x0123456789abcdef) ||
        *(uint64_t *)(target + 48) != UINT64_C(0xfedcba9876543210))
    {
        fprintf(stderr, "atomic exchange mismatch: previous=%016llx target=%016llx\n",
                (unsigned long long)previous, (unsigned long long)*(uint64_t *)(target + 48));
        return 11;
    }

    for (i = 0; i < 4; i++)
    {
        contexts[i].store = store64;
        contexts[i].id = i + 1;
        contexts[i].passed = 0;
        threads[i] = CreateThread(NULL, 0, store_worker, &contexts[i], 0, NULL);
        if (!threads[i])
        {
            fprintf(stderr, "CreateThread failed: %lu\n", GetLastError());
            return 12;
        }
    }
    WaitForMultipleObjects(4, threads, TRUE, INFINITE);
    for (i = 0; i < 4; i++)
    {
        DWORD status;

        GetExitCodeThread(threads[i], &status);
        CloseHandle(threads[i]);
        if (status || !contexts[i].passed)
        {
            fprintf(stderr, "worker %u failed: %lu\n", i, status);
            return 13;
        }
    }

    puts("PASS JIT_CROSS_VIEW positive exact-bytes scalar vector atomic threads");
    return 0;
}

/* A translated store that must not be emulated has to raise a catchable access
 * violation at the faulting address.  Reporting "the process did not return"
 * would accept a livelock, which is the failure this whole change removes. */
static int expect_access_violation(const char *name, void *fault_address, void (*action)(void *),
                                   void *argument)
{
    DWORD code = 0;
    ULONG_PTR reported = 0;

    __try
    {
        action(argument);
    }
    __except (code = GetExceptionCode(),
              reported = GetExceptionInformation()->ExceptionRecord->NumberParameters >= 2
                             ? GetExceptionInformation()->ExceptionRecord->ExceptionInformation[1]
                             : 0,
              EXCEPTION_EXECUTE_HANDLER)
    {
        if (code != EXCEPTION_ACCESS_VIOLATION)
        {
            fprintf(stderr, "%s raised %08lx, expected an access violation\n", name, code);
            return 0;
        }
        if (fault_address && reported != (ULONG_PTR)fault_address)
        {
            fprintf(stderr, "%s faulted at %p, expected %p\n", name, (void *)reported,
                    fault_address);
            return 0;
        }
        return 1;
    }
    fprintf(stderr, "%s returned instead of faulting\n", name);
    return 0;
}

struct store_call
{
    store64_fn store64;
    store128_fn store128;
    void *target;
    const void *value;
};

static void do_store64(void *opaque)
{
    struct store_call *call = opaque;
    call->store64(call->target, UINT64_C(0x1122334455667788));
}

static void do_store128(void *opaque)
{
    struct store_call *call = opaque;
    call->store128(call->target, call->value);
}

static int run_rx_target(void)
{
    struct store_call call = {0};

    call.target = make_target(4096, PAGE_EXECUTE_READ);
    call.store64 = make_jit_function(store64_code, sizeof(store64_code));
    if (!expect_access_violation("rx-target", call.target, do_store64, &call))
        return 90;
    puts("PASS JIT_CROSS_VIEW rx-target rejected with an access violation");
    return 0;
}

/* Covers the per-page arm of the check: the view is still a JIT view, so the
 * ordinary fault path would spin on it, but the page itself is no longer
 * committed.  The obvious way to reach this state is VirtualProtect down to
 * PAGE_EXECUTE_READ, which this fork refuses on a JIT view with
 * ERROR_ACCESS_DENIED; decommitting the page reaches the same check. */
static int run_decommitted_target(void)
{
    struct store_call call = {0};
    SYSTEM_INFO info;
    unsigned char *target;

    GetSystemInfo(&info);
    target = make_target(info.dwPageSize, PAGE_EXECUTE_READWRITE);
    if (!VirtualFree(target, info.dwPageSize, MEM_DECOMMIT))
    {
        fprintf(stderr, "VirtualFree(MEM_DECOMMIT) failed: %lu\n", GetLastError());
        return 5;
    }
    call.target = target;
    call.store64 = make_jit_function(store64_code, sizeof(store64_code));
    if (!expect_access_violation("decommitted-target", call.target, do_store64, &call))
        return 91;
    puts("PASS JIT_CROSS_VIEW decommitted-target rejected with an access violation");
    return 0;
}

static int run_decommitted_crossing(void)
{
    static const unsigned char value[16] = {0};
    struct store_call call = {0};
    SYSTEM_INFO info;
    unsigned char *target;

    GetSystemInfo(&info);
    target = make_target(info.dwPageSize * 2, PAGE_EXECUTE_READWRITE);
    if (!VirtualFree(target + info.dwPageSize, info.dwPageSize, MEM_DECOMMIT))
    {
        fprintf(stderr, "VirtualFree(MEM_DECOMMIT) failed: %lu\n", GetLastError());
        return 6;
    }
    call.target = target + info.dwPageSize - 8;
    call.value = value;
    call.store128 = make_jit_function(store128_code, sizeof(store128_code));
    /* Hardware reports the first byte that cannot be written, so the expected
     * address is the start of the decommitted page - not the store address,
     * which is in the committed page and perfectly writable. */
    if (!expect_access_violation("decommitted-crossing", target + info.dwPageSize, do_store128,
                                 &call))
        return 92;
    puts("PASS JIT_CROSS_VIEW decommitted-crossing rejected with an access violation");
    return 0;
}

/* movntdq is lowered by FEX to an ordinary 128-bit ARM64 store, so this is a
 * positive case, not a rejection case.  Rejection of store forms the decoder
 * does not know is covered by spikes/WINE-001/jit-store/decode-test.c, which
 * exercises the shipped decoder directly; producing an unknown form from guest
 * x64 would test FEX's instruction selection instead of this handler. */
static int run_non_temporal(void)
{
    static const unsigned char value[16] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                                            0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00};
    unsigned char *target = make_target(4096, PAGE_EXECUTE_READWRITE);
    store128_fn store128 = make_jit_function(non_temporal128_code, sizeof(non_temporal128_code));

    memset(target, 0x5a, 32);
    store128(target, value);
    if (!check_bytes(target, value, sizeof(value), "non-temporal store"))
        return 14;
    if (target[16] != 0x5a)
    {
        fprintf(stderr, "non-temporal store wrote past 16 bytes: %02x\n", target[16]);
        return 15;
    }
    puts("PASS JIT_CROSS_VIEW non-temporal exact-bytes");
    return 0;
}

int main(int argc, char **argv)
{
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    if (argc != 2)
    {
        fprintf(stderr, "usage: jit_cross_view.exe MODE\n");
        return 64;
    }
    if (!strcmp(argv[1], "positive"))
        return run_positive();
    if (!strcmp(argv[1], "rx-target"))
        return run_rx_target();
    if (!strcmp(argv[1], "decommitted-target"))
        return run_decommitted_target();
    if (!strcmp(argv[1], "decommitted-crossing"))
        return run_decommitted_crossing();
    if (!strcmp(argv[1], "non-temporal"))
        return run_non_temporal();
    fprintf(stderr, "unknown mode: %s\n", argv[1]);
    return 65;
}
