# GFX-001 result 08 — Deus Ex renders: the blocker was a feature level we advertise and cannot honour

**Author:** Tim Isaev

**Date:** 25 July 2026

**Disposition:** issue #65 closed. The second shortlisted D3D11 title now
reaches its `-benchmark` scene and sustains rendering. #11's measurement is
unblocked; this result does not perform it.

## Outcome

[Result 07](2026-07-25-07-deus-ex-title-scene-blocked.md) left Deus Ex: Mankind
Divided dying on an unattributed `E_INVALIDARG` during Scaleform
initialization, once the ARM64EC delay-import blocker (#59) was out of the way.

DXMT names the call itself, with logging enabled and no instrumentation
required:

```text
err: CreateMTLTextureDescriptorInternal: sample count 8 is not supported.
```

With that fixed the title runs:

| Measurement | Value |
| --- | ---: |
| Presents | 20,213 |
| Span | 274.9 s |
| Mean FPS | 73.53 |
| Interval p50 | 13.475 ms |
| Interval p95 | 19.573 ms |
| Interval p99 | 24.897 ms |
| Intervals over 33.3 ms | 74 |
| Intervals over 100 ms | 6 |
| Shader / pipeline events | 380 / 407 |
| **Non-ok DXMT events** | **0** |

## Whose fault it was

Not the title's, and not `CheckMultisampleQualityLevels`.

`CheckMultisampleQualityLevels1` is honest: it consults
`supportsTextureSampleCount` and reports 0 quality levels for a count the
device cannot do. A title that queries gets the right answer.

But **D3D11 feature level 11_0 guarantees 8x MSAA** for every render-target
format except R32G32B32A32, and DXMT advertises 11_0:

```text
info: Maximum supported feature level: D3D_FEATURE_LEVEL_11_1
info: Using feature level D3D_FEATURE_LEVEL_11_0
```

A conformant title is therefore entitled to ask for 8 samples *without*
querying, which is what Scaleform does. Meanwhile the hardware, probed
directly:

```text
device: Apple M2 Pro
  sample count 1: supported
  sample count 2: supported
  sample count 4: supported
```

So the defect is not a game misbehaving. It is a capability gap we created by
advertising a feature level the device cannot honour, and then failed on when
someone took us at our word.

## The change

[`../instrumentation/0002-d3d11-msaa-clamp.patch`](../instrumentation/0002-d3d11-msaa-clamp.patch)
clamps an unsupported sample count down to the highest the device supports and
reports it once, instead of returning `E_INVALIDARG`.

This renders with fewer samples than the title asked for. That is a visible
difference, which is why it is logged rather than done silently — but it is the
honest end of a promise already made one layer up. The alternatives were worse:
keeping the failure blocks any title that trusts the feature level, and
dropping to a level that only requires 4x MSAA would give up 11_0 features that
titles depend on far more than they depend on 8x.

## What the title does now

In order: window created, `[DXGI] Created swapchain`,
`[SwapChain] Successfully created`, `[NxApp] Swapchain initialized`,
`[NxApp] Renderer initialized`, `[Scaleform] Initializing`,
`[Render] Unknown GPU detected`, `[Validate Settings]` — and then a sustained
render loop. `Unknown GPU detected` is the title not recognising the adapter
string; it validates settings against its own defaults and continues.

## Regression

| Check | Result |
| --- | --- |
| Sir Brante headless | exit 0, ordinary Unity asset lifecycle |
| Sir Brante graphical (exact-policy DXMT D3D11 smoke) | exit 0, **7,420 presents**, 0 non-ok events |
| Deus Ex `-benchmark` | exit 0, 20,213 presents, 0 non-ok events |

Result 06's title is unaffected by the clamp: it never requests a sample count
the device cannot provide, so the new path is not reached.

## One thing #11 will hit

`analyze-title-metrics.py` refuses this title's telemetry:

```text
ValueError: ...t65-bench-01.tsv: timestamps are not monotonic
```

It is not corruption. Across 21,000 rows there are **31** reversals, the
largest 41 µs, from worker threads timestamping before they write. Sir Brante
never tripped it because it does not create pipelines off the render thread;
a AAA engine does.

The analyzer needs to sort, or tolerate sub-millisecond reversals, before #11
can summarise this title. That is #11's work and is deliberately not done here —
this result reports the pacing from an ad-hoc sort so the numbers above are
real, and leaves the tool alone.

## Claim boundary

The title renders. That is all this establishes. It is not the two-title
measurement E3 requires: no cold/warm pair, no shader-stall attribution, no
long-session memory trace, no visual reference. #11 owns that and is now
unblocked.
