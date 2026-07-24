# STORE-001 result 01 — first entitled-build fingerprint and exact-match rerun

**Author:** Tim Isaev
**Date:** 24 July 2026

## Verdict

```text
The Life and Suffering of Sir Brante: build 24280929, 1422 files, 3498258640 bytes
aggregate 1563163e7bdbd3d54566845f45b0406c02a10e0f66c6a97ba4e55bc1f56be88e
rerun evidence: EXACT MATCH (buildid, depot manifests, content aggregate)
```

The D-020 pipeline smoke title, installed entitled via the real Windows Steam client
(existing licensed CrossOver environment — Lane A of the [runbook](../RUNBOOK.md)),
discovered and fingerprinted by `tools/steam-fingerprint.py` from the D-019 identity
inputs: `libraryfolders.vdf` discovery → `appmanifest_1272160.acf` → buildid
24280929 + depot 1272161 manifest id → SHA-256 of all 1,422 installed files folded
into one aggregate. An immediate re-fingerprint reproduced every component exactly.
Full record: [`fingerprint-1272160-first.json`](fingerprint-1272160-first.json)
(255 KB, content hashes only — no account data).

## What this closes and what remains

| Phase-0 row component | State |
| --- | --- |
| Entitled install | ✅ real client, entitled account, real title |
| Exact build fingerprint | ✅ buildid + depot manifest + per-file and aggregate SHA-256 |
| Rerun evidence | ✅ unperturbed EXACT MATCH; **founder 5-min step remains:** rerun `--verify` after a Steam client restart + "Verify integrity of game files" (the realistic perturbation) |
| Runtime-hosted client (Lane B) | Phase-1 scope; this fingerprint is its comparison anchor |

LAB-001's Windows-side reproduction consumes the same JSON as its identity anchor.
