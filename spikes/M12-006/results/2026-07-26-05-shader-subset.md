# M12-006 result 05 — explicit-LOD textures and three wave patterns are GPU-exact

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Green
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (`25F84`)

## Exact inputs

- Tested execution commit
  `94afcc2fee0742b0887f46cd356e1c54a4bb191d`, runtime tree
  `77d5f21cfbdacf8472156f9586942eb6c020a251`, and shader-run manifest
  SHA-256
  `c78ce073ca3431d8c99bd71099409c6b82342ca2d65086bdbba2bd303935645c`.
- The enclosing unsigned staging generation has `SHA256SUMS` digest
  `5cdc5848e8c133ab3582c5f41e70555e64c0c9f038e6b65e89d22540add72079`.
  It is `STAGING_ONLY`; checksums do not establish signer authenticity or
  durable preservation. The snapshot covers tested commit `94afcc2`; this
  later documentation reconciliation is outside it.
- Pinned `dxc.exe` v1.9.2602.24, executed once per shader through Alloy's
  shared Wine/FEX runtime.
- Canonical lowerer `runtime/metal12/ShaderTools/dxil_to_msl.py`.
- `runtime/metal12/Tests/ShaderCorpus/cases.json` and its 11 HLSL cases.
- A deterministic two-level RGBA32Float mip chain (4 × 4 and 2 × 2) whose
  channel values are `mip * 100 + y * 10 + x + channel * 0.25`.
- Xcode 26.3 Metal compiler and the `ShaderRunner`, which consumes
  `AM12ValidateShaderProofConfiguration` from `libAlloyMetal12.a`.

## Verdict

```text
corpus: 10 pass, 1 rejected-with-diagnostic, 0 fail
Metal threadExecutionWidth: 32
m12-003 shader path ok
metal12 shader corpus ok
```

The retained canonical invocation performed exactly one fresh DXC compile per
case, accepted no prior-run cache reads, and recorded `fresh_compiles: 11`,
`cache_hits: 0`, and `compilation_policy: fresh-only-no-cache-read`. Each
compile emits DXIL and disassembly together into private run work, and those
bytes are reused for lowering and GPU validation throughout that evidence
batch. A later complete invocation is a new independent evidence batch rather
than another test iteration inside the first.

The verdict and invocation counts in this document refer to the single
manifest-bound batch identified above. Older corpus runs remain historical
context and are not mixed into these totals.

## New texture coverage

| Shader | HLSL form | Sampler | Coordinates | CPU/GPU result |
| --- | --- | --- | --- | --- |
| `texture_point_cs` | `Texture2D<float4>.SampleLevel(..., 0.0)` | Point, clamp | `(0.375, 0.625)` | Byte-exact `21.0` |
| `texture_bilinear_cs` | `Texture2D<float4>.SampleLevel(..., 1.0)` | Linear, clamp | `(0.5, 0.5)` | Byte-exact `105.5` |

The normalized IR retains resource class and range index, so SRV `t0`,
sampler `s0`, and UAV `u0` cannot collide. Explicit LOD survives into MSL's
`level(...)` sample form. The runner uploads distinct bytes for levels 0 and 1,
and its nearest mip filter makes the integer `SampleLevel` selection explicit.
The independent CPU reference selects the same level from the first-party
fixture, applies point or bilinear minification, and requires every GPU float
word to match the CPU word byte for byte.

## New wave coverage

| Shader | HLSL operation | Lowered MSL | Reference |
| --- | --- | --- | --- |
| `wave_cs` | `WaveActiveSum` | `simd_sum` | Per-32-lane CPU sum |
| `wave_lane_index_cs` | `WaveGetLaneIndex` | `thread_index_in_simdgroup` | Actual pipeline width |
| `wave_prefix_sum_cs` | `WavePrefixSum` | `simd_prefix_exclusive_sum` | Per-32-lane CPU prefix |

The runner records `MTLComputePipelineState.threadExecutionWidth`; the CPU
reference does not hard-code a wave width.

`wave_read_lane_unsupported_cs` proves the remaining boundary fails loudly:

```text
M12003-unsupported: dx.op.waveReadLaneAt
```

The original five scalar/buffer shaders remain byte-exact against their CPU
reference bytes. The existing reference vertex and fragment programs still
lower to 15 and 99 operations and compile as Metal.

## Claim boundary

This proves integer explicit LOD 0 and 1 over a two-level RGBA32Float mip
chain, point and bilinear clamp sampling, active sum, lane index, and exclusive
prefix sum in the straight-line textual-DXC subset. The corpus binds textures
and samplers directly in its runner, so it does not yet prove texture/sampler
descriptor-page virtualization.

Implicit or fractional LOD, mip interpolation, derivatives, mip chains beyond
the tested two levels, gathers, comparison samplers, broader texture
dimensions/formats, full wave semantics, control flow, and general DXIL
ingestion remain unsupported or unmeasured.
