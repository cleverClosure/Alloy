/* Exercise the exact bridge installed into Wine. Author: Timur Isaev */
#include "darwin-jit-resume.h"

#include <libkern/OSCacheControl.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct register_sample
{
    uint64_t x[31], sp;
    unsigned char v[32][16];
    uint64_t nzcv, fpcr, fpsr, padding;
    uint64_t redzone[16];
    uint64_t expected_sp, expected_lr;
};
_Static_assert(offsetof(struct register_sample, expected_sp) == 0x3a0, "assembly layout");
_Static_assert(offsetof(struct register_sample, expected_lr) == 0x3a8, "assembly layout");
extern void alloy_jit_register_probe(void *code, struct register_sample *sample);
extern const unsigned char alloy_jit_sample_start[], alloy_jit_sample_end[];

struct worker
{
    struct alloy_jit_resume *resume;
    struct register_sample sample;
    sigjmp_buf bailout;
    void *code;
    size_t page_size;
    const char *mode;
    int iterations, failed;
    volatile sig_atomic_t faults, restores, nested, bounded;
};
static pthread_key_t worker_key;

static void handler(int signal_number, siginfo_t *info, void *opaque)
{
    struct worker *worker = pthread_getspecific(worker_key);
    ucontext_t *context = opaque;

    (void)info;
    if (!worker)
        _exit(125);
    if (signal_number == SIGUSR2)
    {
        if (!alloy_jit_resume_finish(worker->resume, context))
            _exit(124);
        ++worker->restores;
        return;
    }
    if (signal_number == SIGUSR1)
    {
        ++worker->nested;
        pthread_jit_write_protect_np(0);
        alloy_jit_register_probe(worker->code, &worker->sample);
        return;
    }
    ++worker->faults;
    if (strcmp(worker->mode, "legacy") == 0)
    {
        if (worker->faults >= 4)
        {
            worker->bounded = 1;
            siglongjmp(worker->bailout, 1);
        }
        pthread_jit_write_protect_np(1);
        return;
    }
    if (!alloy_jit_resume_prepare(worker->resume, context))
        _exit(123);
    if (strcmp(worker->mode, "corrupt-gpr") == 0)
        worker->resume->context.__ss.__x[9] ^= 1;
    if (strcmp(worker->mode, "corrupt-simd") == 0)
        ((unsigned char *)&worker->resume->context.__ns.__v[15])[0] ^= 1;
}

static int check_registers(struct worker *worker)
{
    const struct register_sample *sample = &worker->sample;
    int failures = 0;

    for (int i = 0; i < 31; ++i)
    {
        /* Darwin reserves x18 and clears it on kernel entry. The bridge copies
         * its saved value, but the platform does not promise its preservation. */
        if (i == 18)
            continue;
        uint64_t expected = i == 16   ? (uintptr_t)worker->code
                            : i == 30 ? sample->expected_lr
                                      : 0x100u + (unsigned)i;
        if (sample->x[i] != expected)
        {
            fprintf(stderr, "mismatch x%d: %llx != %llx\n", i, sample->x[i], expected);
            ++failures;
        }
    }
    for (int i = 0; i < 32; ++i)
    {
        for (int byte = 0; byte < 16; ++byte)
        {
            if (sample->v[i][byte] != i + 1)
            {
                fprintf(stderr, "mismatch v%d byte %d\n", i, byte);
                ++failures;
            }
        }
    }
    if (sample->sp != sample->expected_sp || sample->nzcv != 0xa0000000 ||
        sample->fpcr != 0x400000 || sample->fpsr != 0x8000011)
    {
        fprintf(stderr, "mismatch SP/NZCV/FPCR/FPSR: %llx/%llx/%llx/%llx\n", sample->sp,
                sample->nzcv, sample->fpcr, sample->fpsr);
        ++failures;
    }
    for (int i = 0; i < 16; ++i)
    {
        if (sample->redzone[i] != UINT64_C(0x5a5a5a5a5a5a5a5a))
        {
            fprintf(stderr, "mismatch redzone[%d]\n", i);
            ++failures;
        }
    }
    return failures;
}

static void *exercise(void *opaque)
{
    struct worker *worker = opaque;
    sigset_t original_mask, expected_mask, actual_mask;
    stack_t alt = {0}, stack_after;
    int direct = strcmp(worker->mode, "direct") == 0;
    int nested = strcmp(worker->mode, "bridge-nested") == 0;
    size_t code_size = (size_t)(alloy_jit_sample_end - alloy_jit_sample_start);

    worker->page_size = (size_t)sysconf(_SC_PAGESIZE);
    worker->resume = alloy_jit_resume_create();
    alt.ss_size = SIGSTKSZ;
    alt.ss_sp = malloc(alt.ss_size);
    worker->code = mmap(NULL, worker->page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (!worker->resume || !alt.ss_sp || worker->code == MAP_FAILED ||
        code_size > worker->page_size || pthread_setspecific(worker_key, worker) ||
        sigaltstack(&alt, NULL))
        _exit(122);
    pthread_jit_write_protect_np(0);
    memcpy(worker->code, alloy_jit_sample_start, code_size);
    sys_icache_invalidate(worker->code, code_size);
    pthread_sigmask(SIG_SETMASK, NULL, &original_mask);
    expected_mask = original_mask;
    if (strcmp(worker->mode, "bridge-blocked") == 0)
    {
        sigaddset(&expected_mask, SIGUSR2);
        sigaddset(&expected_mask, SIGWINCH);
    }
    pthread_sigmask(SIG_SETMASK, &expected_mask, NULL);
    if (sigsetjmp(worker->bailout, 1) == 0)
    {
        for (int i = 0; i < worker->iterations; ++i)
        {
            memset(&worker->sample, 0, sizeof(worker->sample));
            pthread_jit_write_protect_np(direct || nested);
            if (nested)
                raise(SIGUSR1);
            else
                alloy_jit_register_probe(worker->code, &worker->sample);
            worker->failed += check_registers(worker);
            pthread_sigmask(SIG_SETMASK, NULL, &actual_mask);
            sigaltstack(NULL, &stack_after);
            if (actual_mask != expected_mask || (stack_after.ss_flags & SS_ONSTACK) ||
                worker->resume->pending)
            {
                fprintf(stderr, "mismatch signal mask/altstack/bridge state\n");
                ++worker->failed;
            }
            if (worker->failed)
                break;
        }
    }
    pthread_jit_write_protect_np(1);
    pthread_sigmask(SIG_SETMASK, &original_mask, NULL);
    alt.ss_flags = SS_DISABLE;
    if (sigaltstack(&alt, NULL))
        _exit(121);
    free(alt.ss_sp);
    munmap(worker->code, worker->page_size);
    alloy_jit_resume_destroy(worker->resume);
    pthread_setspecific(worker_key, NULL);
    return NULL;
}

int main(int argc, char **argv)
{
    const char *modes[] = {"direct",        "legacy",          "bridge",      "bridge-blocked",
                           "bridge-nested", "bridge-threaded", "corrupt-gpr", "corrupt-simd"};
    int known = 0;
    if (argc != 2)
        return 2;
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i)
        known |= strcmp(argv[1], modes[i]) == 0;
    if (!known || !pthread_jit_write_protect_supported_np())
        return 2;
    if (pthread_key_create(&worker_key, NULL))
        return 2;
    struct sigaction action = {.sa_sigaction = handler, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    sigfillset(&action.sa_mask);
    if (sigaction(SIGBUS, &action, NULL) || sigaction(SIGSEGV, &action, NULL) ||
        sigaction(SIGUSR2, &action, NULL))
        return 2;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR2);
    if (sigaction(SIGUSR1, &action, NULL))
        return 2;
    int count = strcmp(argv[1], "bridge-threaded") == 0 ? 8 : 1;
    struct worker workers[8] = {0};
    pthread_t threads[8];
    for (int i = 0; i < count; ++i)
    {
        workers[i].mode = argv[1];
        workers[i].iterations = count == 8 ? 64 : 1;
        if (count == 1)
            exercise(&workers[i]);
        else if (pthread_create(&threads[i], NULL, exercise, &workers[i]))
            return 2;
    }
    int faults = 0, restores = 0, failures = 0, bounded = 0, nested = 0;
    for (int i = 0; i < count; ++i)
    {
        if (count > 1 && pthread_join(threads[i], NULL))
            return 2;
        faults += workers[i].faults;
        restores += workers[i].restores;
        failures += workers[i].failed;
        bounded += workers[i].bounded;
        nested += workers[i].nested;
    }
    printf(
        "mode=%s threads=%d iterations=%d faults=%d restores=%d nested=%d failures=%d bounded=%d\n",
        argv[1], count, workers[0].iterations, faults, restores, nested, failures, bounded);
    if (bounded)
        return 3;
    int expected = strcmp(argv[1], "direct") == 0 ? 0 : count * workers[0].iterations;
    if (faults != expected || restores != (strcmp(argv[1], "legacy") == 0 ? 0 : expected))
        return 4;
    return failures ? 1 : 0;
}
