// Author: Timur Isaev
#include <cstdint>

using ntstatus_t = std::int32_t;
using unixlib_entry_t = ntstatus_t (*)(void *);

static constexpr ntstatus_t status_success = 0;
static constexpr ntstatus_t status_not_supported = static_cast<ntstatus_t>(0xc00000bbU);

static ntstatus_t set_hardware_tso_control(void *)
{
    return status_not_supported;
}

static ntstatus_t set_kernel_unaligned_atomic_control(void *)
{
    return status_not_supported;
}

static ntstatus_t advise_memory(void *)
{
    return status_not_supported;
}

static ntstatus_t set_vma_name(void *)
{
    return status_not_supported;
}

static ntstatus_t get_shm_stats_vma(void *)
{
    return status_not_supported;
}

static ntstatus_t delete_shm_stats_file(void *)
{
    return status_success;
}

extern "C" __attribute__((visibility("default"))) const unixlib_entry_t __wine_unix_call_funcs[] = {
    set_hardware_tso_control,
    set_kernel_unaligned_atomic_control,
    advise_memory,
    set_vma_name,
    get_shm_stats_vma,
    delete_shm_stats_file,
};
