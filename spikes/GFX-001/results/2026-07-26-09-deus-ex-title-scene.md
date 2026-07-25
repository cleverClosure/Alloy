# GFX-001 result 09 — second entitled D3D11 title scene measured: Deus Ex

**Author:** Timur Isaev

**Date:** 26 July 2026

**Disposition:** title 2 of 2 measured; the two-title E3 evidence gate is green
at representative-scene scope. The known 8× MSAA capability mismatch remains a
scoped, logged 4× clamp rather than a silent correctness claim.

## Claim boundary

Deus Ex: Mankind Divided's built-in benchmark is a repeatable real-game D3D11
scene. It now has matched cold/warm shader-cache telemetry, title-marker-bounded
frame pacing, shader and pipeline attribution, a 30-minute one-PID memory trace,
and visual references through Alloy's EC Wine + FEX + per-process DXMT route.

This closes the second half of issue #11 and satisfies E3's literal two-title
wording. It does not certify every scene, quality setting, or gameplay path in
the title. DXMT still cannot provide the 8× MSAA that D3D feature level 11_0
promises; the tracked provider patch logs the request and renders at the
hardware-supported 4× sample count.

## Exact input and host

| Input | Value |
| --- | --- |
| Title | Deus Ex: Mankind Divided (GOG `gameId 1296690054`), `v1.19 build 801.0` |
| Store build | GOG build `53307442018838439` |
| Game executable SHA-256 | `cf4805608f9cc7129a8f04ade8eeefdf1f0cd849a1f702dfe8f0cd06f2f53ee8` |
| GOG manifest SHA-256 | `9f277c156af56d0ba48ba1745423f315e7e3cc1e32b79023d26d47f60722d75c` |
| Wine source tip | `420c70bdcb7615c3dc0395d162f93645f098fe56` |
| Wine `ntdll.so` SHA-256 | `f24783b4be0d7c3d8fd8cb69674a125a38a5498735b1077e5209743e0690100d` |
| DXMT | `e520fea415ba4b82b0c346dae77bbb1be4897453` plus tracked D3D11 metrics and MSAA-clamp patches |
| D3D11 / DXGI SHA-256 | `f2ec299a66cc3152692de814091ffdc4d66c44ab0fba92610881c4f92cf6401e` / `9c222f6ab4ae76487395f86de185c9757c6c415a42e44f53163608070d30861a` |
| FEX ARM64EC DLL SHA-256 | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Host | MacBook Pro (M2 Pro, 12 cores, 16 GB), macOS 26.5.2 (`25F84`) |

The source worktrees are shared lab state and carried uncommitted diagnostics
during this run. Commit names are therefore not treated as complete binary
identity: the input record and result summaries carry exact loaded-artifact and
raw-stream SHA-256 values.

## Scenario and automation

The scenario is the title's built-in benchmark at 1280×720 windowed, D3D11,
VSync off, DX12 off. The `-benchmark` argument skips the launcher and intro
videos; it does **not** start the benchmark. The real path is Main menu →
Extras → Benchmark.

[`../scenarios/deus-ex-mankind-divided-benchmark.json`](../scenarios/deus-ex-mankind-divided-benchmark.json)
records the exact gates and visual anchors. The tracked automation:

- localizes Wine's Documents directory beneath the isolated prefix, so the
  title log cannot mix with another runtime;
- identifies one host process whose command contains `DXMD.exe -benchmark` and
  rejects Wine's `start.exe`;
- captures only that process's 1280×752 logical window, finds `EXTRAS` and
  `BENCHMARK` with Vision OCR, and requires selected-row luminance before Return;
- retries ignored keyboard events instead of assuming a fixed key count;
- accepts the scene only after the title logs statistics capture start and
  benchmark stop, pairing both markers with completed DXMT Presents;
- keeps one exact PID alive across result/menu transitions for the repeated
  30-minute session and verifies its command on every memory sample.

The rejected first automation trial is why the visual state check exists: one
Down event was ignored and entered Jensen's Stories. No telemetry from that
trial is evidence.

## Cold/warm results

Cold started with a new empty shader-cache directory. Warm reused that exact
directory and the persistent isolated wineserver. Both scene windows begin at
the title's statistics-capture marker and end at its benchmark-stop marker.

### Marker-bounded benchmark scene

| Metric | Cold | Warm |
| --- | ---: | ---: |
| Analyzed DXMT span | 101.758 s | 102.548 s |
| Presents / intervals | 5,386 / 5,385 | 5,066 / 5,065 |
| Mean FPS | 52.925 | 49.394 |
| Interval p50 | 16.452 ms | 17.999 ms |
| Interval p95 | 30.266 ms | 32.090 ms |
| Interval p99 | 55.532 ms | 50.330 ms |
| Maximum interval | 762.259 ms | 438.508 ms |
| Intervals over 33.333 / 50 / 100 ms | 127 / 64 / 20 | 198 / 52 / 18 |
| Shader compiles / cache hits | 584 / 0 | 9 / 681 |
| Pipeline creations | 829 | 958 |
| Non-ok events | 0 | 0 |

### Full-stream cache and startup attribution

| Metric | Cold | Warm |
| --- | ---: | ---: |
| Telemetry span | 149.062 s | 152.868 s |
| Shader compiles / cache hits | 1,368 / 0 | 9 / 1,365 |
| Compile mean / p95 / max | 16.271 / 65.572 / 295.207 ms | 162.283 / 445.743 / 445.875 ms |
| Pipeline creations | 1,727 | 1,731 |
| Pipeline mean / p95 / max | 3.825 / 19.985 / 255.078 ms | 7.710 / 37.410 / 338.660 ms |
| Input-order reversals / maximum | 71 / 14.901 ms | 116 / 2.168 ms |
| Non-ok events | 0 | 0 |

Warm served 1,365 of 1,374 observed shader events from the cache (99.345%) but
still compiled nine shaders. Three of those misses took 431.065–445.875 ms and
completed in the warm scene's longest 438.508 ms interval, alongside four
graphics-pipeline events. The durations overlap across worker threads and must
not be summed as serial frame time, but the alignment supports shader/PSO
attribution for that interval. Cold's longest 762.259 ms interval contained no
shader or pipeline completion; its second-longest attributed interval was
273.237 ms with one shader and three pipelines totaling 264.549 ms of
overlapping work.

The cache is therefore highly effective, not complete, and warm does not erase
all scene stutter. The nine misses are retained as a measured limitation rather
than reported as zero. DXMT worker threads also timestamp before acquiring the
telemetry output lock; the analyzer stably restores event-time order and records
the original reversals instead of rejecting or hiding them.

Committed summaries:

- [cold full stream](data/issue-11/deus-ex-cold-full.json)
- [warm full stream](data/issue-11/deus-ex-warm-full.json)
- [cold benchmark scene](data/issue-11/deus-ex-cold-scene.json)
- [warm benchmark scene](data/issue-11/deus-ex-warm-scene.json)
- [cold title markers](data/issue-11/deus-ex-cold-markers.json)
- [warm title markers](data/issue-11/deus-ex-warm-markers.json)

## 30-minute repeated-scene session

The final soak kept PID `85589` alive for 15 separately verified benchmark
cycles. The memory sampler captured 1,801 one-second samples over exactly 1,800
seconds; the title-marker windows cover 1,476.095 seconds of rendered benchmark
content. Every cycle used the same PID, all 15 reached distinct start and stop
markers, and the full 111,960-event DXMT stream contained zero non-ok events.

| Metric | Result |
| --- | ---: |
| RSS start / end / delta | 1,230.984 / 971.141 / −259.844 MiB |
| RSS minimum / peak | 570.312 / 1,919.016 MiB |
| Tail-half RSS start / end / delta | 990.266 / 971.141 / −19.125 MiB |
| Full / tail-half least-squares RSS slope | +193.646 / +114.838 MiB/hour |
| Virtual-memory start / end / delta | 1,054,759.891 / 1,056,310.000 / +1,550.109 MiB |
| First / last scene mean FPS | 52.761 / 53.240 |
| First / last scene p95 interval | 30.162 / 29.748 ms |
| First / last scene p99 interval | 37.228 / 36.190 ms |
| First / last scene maximum interval | 605.933 / 315.083 ms |
| First / last scene intervals over 100 ms | 9 / 1 |
| Full-stream shader compiles / cache hits | 3 / 1,381 |
| Full-stream pipeline creations / non-ok events | 1,752 / 0 |

RSS is strongly scene-phase dependent, so the positive least-squares values are
retained but are not treated alone as a leak verdict. Like-for-like samples at
successive scene-start offsets are non-monotonic: cycle 1 was 1,230.984 MiB,
cycle 15 was 973.703 MiB, and cycles 11–15 stayed between 942.547 and 1,118.547
MiB. The 1,919.016 MiB peak also drained to 971.141 MiB before sampling ended.
Together with the negative whole-window and tail-window deltas, this run shows
no sustained resident-memory accumulation across the repeated scene. The
virtual-size increase is reported separately because address-space reservation
is not resident memory.

The first cycle still observed three shader compiles and 589 cache hits; the
remaining 14 scene windows observed no shader compiles, and the last 12
observed no shader or pipeline creation events. First-to-last p95 and p99 frame
intervals remained comparable while the count of intervals over 100 ms fell
from nine to one. This is a stability result, not a promise that every repeated
cycle is free of isolated long frames.

Committed soak evidence:

- [full telemetry and memory summary](data/issue-11/deus-ex-soak.json)
- [session identity and raw-stream hashes](data/issue-11/deus-ex-soak-session.json)
- [all 15 marker-bounded cycle rollups](data/issue-11/deus-ex-soak-cycles.json)
- [first scene detail](data/issue-11/deus-ex-soak-first-scene.json)
- [last scene detail](data/issue-11/deus-ex-soak-last-scene.json)
- [exact runtime input hashes and settings](data/issue-11/deus-ex-run-inputs.json)

## Visual references

- [shopping-area market view](evidence/issue-11/2026-07-26-deus-ex-benchmark-frame-a.jpg)
- [guarded corridor view](evidence/issue-11/2026-07-26-deus-ex-benchmark-frame-b.jpg)
- [SHA-256 and capture manifest](evidence/issue-11/deus-ex-manifest.json)

Both images are exact macOS window captures from the final one-PID soak, cycles
2 and 7 respectively. The D3D11 content is logically 1280×720 inside a
1280×752 window; the Retina window capture plus shadow is 2696×1640 pixels.
Neither image is generated or reconstructed.

## Two-title verdict

**Green at representative-scene scope.** Sir Brante result 06 and this result
provide the two real D3D11 scenes issue #11 requires. Both have exact
entitled-build identity, repeatable scene automation, cold/warm frame pacing,
shader-stall attribution, long-session memory evidence, and actual visual
references.

The remaining graphics defect is scoped rather than hidden: this host supports
1×/2×/4× sampling while DXMT advertises feature level 11_0, so the provider
logs and clamps the title's unquerying 8× request to 4×. That visible
correctness tradeoff remains part of the title evidence and any future
certification decision.
