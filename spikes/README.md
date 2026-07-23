# Phase-0 Spikes

**Author:** Tim Isaev

One directory per spike ID from [doc 16](../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md).
Acceptance rules are doc 16 §8 — the binding ones here:

- a demo without measurement does not close a spike;
- a failed hypothesis is a successful spike if it produces a clear decision;
- spike code is disposable unless it meets production standards;
- results update the relevant ADR, risk, roadmap, and architecture documents.

Layout per spike:

```text
spikes/<ID>/
  SPIKE.md      # hypothesis, method, pass/fail — committed
  results/      # dated findings notes + measurements — committed
  work/         # scratch: builds, patches-in-progress, logs — NOT committed
```

Evidence index: [Phase-0 status](PHASE-0-STATUS.md)

Active: [CPU-001](CPU-001/SPIKE.md) · [WINE-001](WINE-001/SPIKE.md)

Closed: [ROLLBACK-001](ROLLBACK-001/SPIKE.md)
