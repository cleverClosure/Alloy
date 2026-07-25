# GFX-001 real-title measurement harness

**Author:** Timur Isaev

**Scope:** D3D11 title pacing, shader/PSO stalls, process memory, and macOS visual
references.

## Instrumented provider

Apply
[`../instrumentation/0001-d3d11-title-metrics.patch`](../instrumentation/0001-d3d11-title-metrics.patch)
from the DXMT source root, then rebuild the D3D11 provider. The patch is opt-in:
without `DXMT_METRICS_PATH`, it opens no file and takes only the singleton/timestamp
branches at the instrumented call sites.

With `DXMT_METRICS_PATH=/absolute/path.tsv`, DXMT truncates that file at process start
and emits:

```text
timestamp_ns  event  object  duration_ns  status  detail
```

Events cover every `Present`, shader cache lookup/compile, and graphics, compute,
geometry, or tessellation pipeline creation. The timestamp uses
`std::chrono::steady_clock`; event and duration fields are nanoseconds.

Set `DXMT_SHADER_CACHE_PATH` to an explicit, isolated directory for comparable cache
pairs. A cold run must point to a previously absent/empty directory. Its warm partner
must reuse that exact directory.

## Analysis

`analyze-title-metrics.py` validates the TSV schema, stably restores timestamp
order when worker threads write adjacent rows out of order, records the reversal
count and maximum backward delta, then reports:

- present-interval and present-call mean/p50/p95/p99/max;
- mean FPS and frame-budget threshold counts;
- longest intervals with shader/PSO events correlated into the same interval;
- shader cache hits, compiles, failures, and compile durations;
- PSO counts, types, failures, and creation durations;
- optional RSS/virtual-memory start, end, peak, delta, and regression slope.

Example:

```sh
python3 -B spikes/GFX-001/harness/analyze-title-metrics.py \
  /absolute/run.tsv \
  --memory /absolute/memory.tsv \
  --start-seconds 90 \
  --label title-scene-soak \
  --output /absolute/summary.json
```

Run its regression test with:

```sh
python3 -B -m unittest \
  spikes/GFX-001/harness/test_analyze_title_metrics.py
```

## Memory sampling

`sample-process-memory.sh` samples one exact PID each second. It checks the process
command against a caller-supplied unique fragment before every sample, so a recycled
PID or another title instance cannot silently contaminate a run.

## Sir Brante cold/warm pair

`run-sir-brante-cache-pair.sh PAIR_ID DURATION_SECONDS` uses the required environment
from `spikes/STORE-001/runtime-launch/launch-sir-brante.sh`. It prepares the isolated
prefix once, starts cold with a new shader-cache directory, marks the isolated
wineserver persistent, starts warm with the same cache/server, and analyzes both
telemetry streams.

The title launcher seeds a muted, windowed 1280×720 configuration. `ALLOY_SAVE_SEED`
may point to an entitled local `Saves/` directory; the copy stays beneath the ignored
work root and is never included in evidence artifacts.

The deterministic UI sequence and visual anchors are recorded in
[`../scenarios/sir-brante-riders-on-the-road.json`](../scenarios/sir-brante-riders-on-the-road.json).
The scenario also records a safe foreground cadence: this Unity build stops
presenting while inactive, so wall-clock waiting is not a valid scene hold. Mark and
trim the pacing window only after foreground rendering is stable.

## Deus Ex benchmark scene

`run-deus-ex-cache-pair.sh PAIR_ID DURATION_SECONDS` applies the same cache-pair
contract to the title's deterministic built-in benchmark. The `-benchmark`
argument skips the launcher and intro videos; it does not select the benchmark.
`drive-deus-ex-benchmark.swift` captures only the exact DXMD window, uses Vision
OCR to find `EXTRAS` and `BENCHMARK`, verifies the selected row by background
luminance, and retries dropped keys. A run is accepted only when the title log
reports benchmark statistics start and stop and both gates pair with completed
DXMT Presents.

The pair prepares the isolated prefix once, starts cold with a new cache
directory, keeps the wineserver alive, and starts warm with that exact cache
and server. It emits a full-stream summary plus a marker-bounded scene summary
for each partner. The launcher localizes Wine's Documents directory inside the
ignored prefix so title logs and crash artifacts do not mix with another
runtime.

`run-deus-ex-soak.sh RUN_ID DURATION_SECONDS` keeps one exact DXMD process alive
and repeats that verified benchmark scene. Sampling begins at the first title
statistics gate, runs once per second for the requested duration, and verifies
the original PID's `DXMD.exe -benchmark` command on every sample. Result-dialog
recovery returns through the main menu; every cycle uses new title-log
occurrence baselines and gets its own marker-bounded scene summary. Point
`ALLOY_DXMT_SHADER_CACHE_PATH` at the completed pair's cache for a warm
long-session run.

## Visual capture wrapper

Build a LaunchServices-aware test app beneath a spike work directory:

```sh
spikes/GFX-001/harness/build-macos-wine-app.sh \
  /absolute/repo/spikes/GFX-001/work/TitleCapture.app \
  com.timurisaev.AlloyTitleCapture \
  "Alloy Title Capture"
```

Launch the app with macOS `open`, passing these environment variables:

- `ALLOY_WINE_BINARY`
- `ALLOY_POLICY_SNAPSHOT_PATH`
- optional `ALLOY_LAUNCH_LOG_PATH`
- the same `WINEPREFIX`, `WINEDLLPATH`, DXMT metric/cache, and runtime variables as
  the shell launcher

The wrapper keeps the policy snapshot on inherited descriptor 9 and follows the
non-Retina convention used by the Wine title path. For Sir Brante, the persisted
`ScreenMode: 3` setting is what produced full 1280×720 menu sizing and correct hit
testing in this run.

Storefront login, purchase, download, integrity verification, and other account
actions are deliberately outside this harness. Visual references come only from
entitled builds that the founder installed manually.
