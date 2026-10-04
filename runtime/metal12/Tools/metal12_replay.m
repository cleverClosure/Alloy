/*
 * Alloy Metal12 generic trace replayer.
 * Author: Timur Isaev
 */

#include "../include/AlloyMetal12.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, const char **argv)
{
    if (argc < 3 || argc > 4)
    {
        puts("usage: metal12_replay <trace.am12> <output.bmp> [repeat-count]");
        return 2;
    }
    uint32_t repeat = argc == 4 ? (uint32_t)strtoul(argv[3], NULL, 10) : 1u;
    AM12ReplaySummary summary = {0};
    if (!repeat || !AM12ReplayTrace(argv[1], argv[2], NULL, repeat, &summary))
        return 1;

    printf("replay: runs=%u stable=%u digest=%016llx\n", summary.runs, summary.stable_runs,
           (unsigned long long)summary.image_digest);
    printf("metric: mean_setup_ms=%.3f\n", summary.mean_timings.setup_ms);
    printf("metric: mean_first_frame_ms=%.3f\n", summary.mean_timings.first_frame_ms);
    printf("metric: mean_warm_mean_ms=%.3f\n", summary.mean_timings.warm_mean_ms);
    printf("metric: mean_warm_p50_ms=%.3f\n", summary.mean_timings.warm_p50_ms);
    printf("metric: mean_warm_p95_ms=%.3f\n", summary.mean_timings.warm_p95_ms);
    printf("metric: last_setup_ms=%.3f\n", summary.last_run.setup_ms);
    printf("metric: last_first_frame_ms=%.3f\n", summary.last_run.first_frame_ms);
    printf("metric: last_warm_mean_ms=%.3f\n", summary.last_run.warm_mean_ms);
    printf("metric: last_warm_p50_ms=%.3f\n", summary.last_run.warm_p50_ms);
    printf("metric: last_warm_p95_ms=%.3f\n", summary.last_run.warm_p95_ms);
    printf("metric: changed_pixels=%zu\n", summary.last_run.changed_pixels);
    puts("status: PASS");
    return 0;
}
