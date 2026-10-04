<!-- Author: Timur Isaev -->

# Synthetic content-store and identity performance baseline

`run-perf-matrix.sh` measures production GC, catalog rebuild, loopback transport,
and the identity scanner against deterministic local fixtures. It first delays
one real GC invocation and requires the same comparison used by the clean gate
to reject it. It then collects three independent samples of every case and
compares their medians with the committed baseline.

```sh
runtime/content-store/run-perf-matrix.sh
runtime/content-store/run-perf-matrix.sh --output /tmp/performance-rerun.json
runtime/content-store/run-perf-matrix.sh --record-baseline /tmp/proposed-baseline.json
```

Recording writes only the explicitly requested file. Updating the committed
baseline is a reviewed source change; ordinary CI never learns a new threshold
from its own run. Swift build/setup time is excluded from samples but included
in the bounded gate's total wall time. All Swift commands use the parser
harness's checked macOS descendant supervisor.

| Case | Timed operation | Correctness control |
| --- | --- | --- |
| GC, 10 and 100 generations | `collectGarbage`, including journal recovery, reachability, sweep and catalog reconciliation | Exactly N−2 generations removed, active/rollback and shared payload retained; second collection removes zero |
| Catalog, 10, 100 and 1,000 objects | `rebuildCatalog` over valid on-disk objects | Exact inventory count/byte total and a consistent disk/catalog report |
| Fresh transport, 196,865 bytes | Whole verified object fetch from a local HTTP fixture | Exact payload and transferred byte count, one request, no Range header |
| Resumed transport, same payload | Completion from a durable 65,536-byte checkpoint, including resume validation and remaining transfer | Exact checkpoint, Range request, 131,329 transferred bytes, two total requests and identical published payload |
| Identity, 100, 1,000 and 20,000 files | Fault-probe scan process over milestone 4's synthetic recipe | Independent Python digest oracle and canonical fingerprint equality |

The resumed completion time and its ratio to fresh completion expose the cost
of the resume path for this small loopback workload. The initial interrupted
transfer is fixture setup and excluded. The ratio is not a claim about internet
throughput or a decomposition of CPU cost from bytes avoided. Identity samples
include process startup, metadata parsing, hashing, canonical encoding and
output persistence and Swift readback (`scan_cli`); Python oracle validation
follows the timer.
Content samples use monotonic in-process timers.
Fixture creation, store activation, compiler work and cleanup are outside the
sampled intervals. Every sample receives its own content store; the identity
recipe is regenerated for each gate and scanned repeatedly, so filesystem cache
warmth is not controlled. This is a regression baseline, not cold-cache capacity
planning or a product latency promise.

The threshold for each median is **max(5 × baseline median, baseline median +
0.1 seconds)**. This conservative first threshold tolerates shared hosted-runner
and APFS variance while catching large regressions. Raw three-sample values are
committed so a smaller threshold can later be justified from repeated evidence.
The deliberate delay is larger than the exact stored GC limit and happens
inside the measured production-operation interval. It must produce a named
failure before all unchanged measurements are accepted.

The existing fast CI gate runs this bounded matrix and the previously full-tier
content-store stress matrix. No workflow, job or schedule is added. The fixture
recipe digest, effective per-title byte counts/digests and content workload sizes
are pinned in the baseline; a recipe change fails until a new
baseline is explicitly generated, inspected and committed.
