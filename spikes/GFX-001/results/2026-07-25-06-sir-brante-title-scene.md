# GFX-001 result 06 — first entitled D3D11 title scene measured: Sir Brante

**Author:** Timur Isaev

**Date:** 25 July 2026

**Disposition:** title 1 of 2 measured; graphics evidence green for this scene; E3
remains open until a second shortlisted D3D11 title is installed and measured.

## Claim boundary

This is the first GFX-001 result from a purchased commercial title rather than a
test guest written for the spike. The exact entitled Steam build reaches an
interactive saved narrative scene through Alloy's EC Wine + FEX + per-process DXMT
route. It has repeatable scene actions, cold/warm shader-cache telemetry, frame
percentiles, shader/PSO timing, a 30-minute memory trace, and visual references.

It does **not** close issue #11 or E3 by itself. The acceptance wording requires two
titles; only Sir Brante is installed locally. No storefront login, download, or
account action was automated to manufacture a second input.

## Exact input and host

| Input | Value |
| --- | --- |
| Title | The Life and Suffering of Sir Brante (`appid 1272160`) |
| Build | Steam build `24280929` |
| Game executable SHA-256 | `1fb707b113f25388a6dacdd81140bf2205f4fe93c71e83d3169e58ab98f95455` |
| Wine | `8d5974ac877d19696c61dba2a2672cfa18c3ad20` |
| DXMT | `e520fea415ba4b82b0c346dae77bbb1be4897453` plus the tracked D3D11-only instrumentation patch |
| FEX ARM64EC DLL SHA-256 | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Host | MacBook Pro (M2 Pro, 12 cores, 16 GB), macOS 26.5.2 (`25F84`) |

The build fingerprint is the STORE-001 entitled artifact. An existing local save was
copied into the ignored isolated prefix; save bytes and paths are not evidence
artifacts.

## Scenario and automation

The scenario is Chapter II, year 1127, **Riders on the Road**, at 1280×720 windowed,
60 FPS target, VSync 0, audio muted. The repeatable coordinate sequence, expected
screens, final visual anchor, and four-page transition probe are recorded in
[`../scenarios/sir-brante-riders-on-the-road.json`](../scenarios/sir-brante-riders-on-the-road.json).

The title launch harness now:

- compiles policy before the first Wine process and gives every Wine utility the
  immutable policy snapshot on descriptor 9;
- seeds UTC plus the full Wine time-zone catalog and a deterministic
  `ScreenMode: 3` 1280×720 configuration;
- optionally imports an entitled save only into the ignored prefix;
- accepts explicit per-run metric and shader-cache paths;
- can retain the wineserver between cold/warm partners while stopping only the game;
- verifies/restores a non-empty `windowscodecs.dll` from the exact Wine build.

The tracked LaunchServices wrapper provides stable macOS app identity for visual
automation. It never contains credentials or title data.

## Measurement path

[`../instrumentation/0001-d3d11-title-metrics.patch`](../instrumentation/0001-d3d11-title-metrics.patch)
adds opt-in telemetry only under `src/d3d11/`; the clean-room-excluded D3D12 subtree
was neither read nor changed. With `DXMT_METRICS_PATH`, it records:

- every completed `Present` and its call duration;
- shader cache hits versus real compiles and their durations;
- graphics/compute/geometry/tessellation PSO creation and duration;
- status and a stable object/event number.

`analyze-title-metrics.py` computes present-interval distributions and correlates
shader/PSO completion into the same frame interval. These are CPU-side completed
Present intervals, not display-scanout timestamps. Raw streams remain in ignored
work storage; committed JSON summaries carry their SHA-256 digests.

## Results

### Cold/warm deterministic scene pair

Cold used a newly created, empty shader-cache directory. Warm reused that exact
directory and the same persistent wineserver; the server PID was checked after cold
shutdown and again after warm shutdown. Both partners followed the same coordinate
sequence and held the mounted-riders anchor. Because this Unity build pauses
`Present` while inactive, an inert point on the illustration was clicked every 10
seconds and each pacing marker was set only after foreground rendering was stable.

| Metric | Cold | Warm |
| --- | ---: | ---: |
| Analyzed scene span | 59.969 s | 59.976 s |
| Presents / intervals | 3,614 / 3,613 | 3,614 / 3,613 |
| Mean FPS | 60.248 | 60.241 |
| Interval p50 | 16.589 ms | 16.556 ms |
| Interval p95 | 18.286 ms | 18.488 ms |
| Interval p99 | 19.946 ms | 19.900 ms |
| Maximum interval | 60.006 ms | 65.007 ms |
| Intervals over 33.333 / 50 / 100 ms | 4 / 3 / 0 | 3 / 3 / 0 |

Committed summaries:
[cold scene](data/issue-11/sir-brante-cold-scene.json),
[warm scene](data/issue-11/sir-brante-warm-scene.json),
[cold full stream](data/issue-11/sir-brante-cold-full.json), and
[warm full stream](data/issue-11/sir-brante-warm-full.json).
The full streams intentionally retain loading and inactive-window gaps; only the
marker-bounded scene summaries are pacing evidence.

### 30-minute scene hold

The exact game PID was sampled once per second for 1,800 seconds (1,801 samples).
RSS started and peaked at 769.484 MiB, reached a 70.703 MiB minimum, and ended at
73.078 MiB: a −696.406 MiB endpoint delta and −518.874 MiB/hour full-trace linear
slope. The tail half fell from 335.281 to 73.078 MiB. Resident memory therefore did
not show monotonic long-session growth.

Virtual size was 492,248.094 MiB at start, 492,562.469 MiB at end, and
492,848.359 MiB at peak. The +314.375 MiB endpoint change is 0.064% of the initial
reserved address space; it did not turn into resident growth.

The uninterrupted foreground render segment after the 90-second marker lasted
1,361.325 seconds, with 81,964 presents, 60.208 mean FPS, 18.642 ms p95,
20.139 ms p99, and 255.657 ms maximum. It had 79 intervals over 33.333 ms
(0.096%), 66 over 50 ms (0.081%), and one over 100 ms (0.001%).

The full stream transparently retains one 277.200-second no-`Present` gap late in
the unattended run. The title resumed normally, emitted no error, and the same
focus-sensitive pause was reproduced during the cache pair, so this is classified
as inactive-window suspension rather than a shader or pipeline stall. Memory
sampling continued throughout it.

Committed summaries:
[full soak and memory](data/issue-11/sir-brante-soak.json) and
[uninterrupted active window](data/issue-11/sir-brante-soak-active-window.json).

### Shader/PSO stall attribution

Cold performed 13 real shader compiles (2.565 ms mean, 4.815 ms p95,
5.550 ms maximum); warm reported 13 cache hits and zero compiles. Each process
created nine graphics PSOs. Cold PSO creation peaked at 0.227 ms and warm at
1.502 ms.

Neither 60-second scene window nor the uninterrupted soak segment contained any
shader or PSO event. Loading/transition intervals that happened to contain cold
compiles were hundreds of milliseconds long while the correlated compile work was
only 1.342–4.128 ms, so the trace does not support attributing those transitions to
shader compilation.

No shader or pipeline event returned an error.

## Visual references

- [Riders on the Road — gate page](evidence/issue-11/2026-07-25-sir-brante-riders-on-the-road.jpg)
- [Riders on the Road — mounted-riders transition](evidence/issue-11/2026-07-25-sir-brante-riders-illustration.jpg)
- [SHA-256 and capture manifest](evidence/issue-11/manifest.json)

Both captures are the actual 1280×720 D3D11 content inside a 1280×752 macOS window
capture; neither is a generated or reconstructed image.

## Two launch blockers found and closed in the harness

1. The early isolated prefix lacked Wine's time-zone catalog. Unity's managed code
   repeatedly raised `InvalidTimeZoneException` and never left loading. Policy-aware
   `wineboot -u` under deterministic `TZ=UTC`, now conditional on the catalog key,
   registers the required zones.
2. One prefix update left `windowscodecs.dll` as a zero-byte PE placeholder,
   so UnityPlayer failed with `STATUS_INVALID_FILE_FOR_SECTION (c0000020)`. The harness
   now verifies the builtin before any dependent utility/game and restores the exact
   build artifact if it is absent or empty. The repaired hash is
   `e67f093aa532cac2b6aed105fb949f4526f23c4252a692fd537f1f4bc176e8e0`.

The original CrossOver bottle and its running process were never modified or stopped.

## Verdict

**Green for title 1 of 2.** This exact entitled D3D11 scene renders correctly,
converts all observed cold shader work into warm cache hits, sustains approximately
60 FPS with sub-20 ms p99 in matched scene windows, shows no shader/PSO stall in
steady state, and shows no monotonic RSS growth across 30 minutes. The foreground
cadence is now part of the reproducible scenario so inactive-window suspension
cannot silently contaminate later pacing windows.

E3 and issue #11 remain open. A second shortlisted D3D11 title must be installed
manually, then measured with the same pacing, memory, stall-attribution, and visual
evidence standard before the two-title acceptance claim can be made.
