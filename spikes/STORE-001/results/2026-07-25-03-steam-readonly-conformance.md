# STORE-001 result 03 — the code was already read-only; the backlog still told us to build the opposite

**Author:** Tim Isaev
**Date:** 25 July 2026
**Scope:** counsel checklist item 6, Steam automation (issue #25)
**Gate:** `spikes/STORE-001/steam-readonly/steam-automation-gate.sh`

## Verdict

**GREEN, with one substantive correction to the design.**

Everything Alloy currently *runs* against Steam was already inside the permitted
posture, and the check confirms it byte for byte. The finding is not in the code.
It is that the v1 design still committed us to the prohibited flows in the one
document engineering would have built from, and justified them with the exact
argument the pre-counsel verdict rejects by name.

## What the implementation actually does

Two pieces of first-party code touch Steam, and both were already compliant:

| Component | Behaviour | Posture |
| --- | --- | --- |
| `tools/steam-fingerprint.py` | parses `libraryfolders.vdf` and `appmanifest_*.acf`, hashes installed files, writes its own JSON elsewhere | read-only discovery — permitted |
| `spikes/STORE-001/runtime-launch/launch-sir-brante.sh` | launches an already-installed executable after verifying it against a committed fingerprint | user-initiated local launch — permitted |
| `spikes/STORE-001/RUNBOOK.md` lane A | the founder signs in and installs **in the Steam client's own UI**, then the tool observes the result | user-operated client action — permitted |

No `steamcmd` invocation, no credential or session material, no simulated input
and no process control over the client exists anywhere in the tree.

## What the gate proves

The read-only claim is an assertion about what the code does to a user's library,
so the gate proves it by doing it: it builds a throwaway two-folder Steam library,
records content, size, mode and mtime for every path, runs the shipped discovery
tool in all four modes from a working directory outside the library, and compares.
Access time is deliberately excluded, because reading is the permitted behaviour
and reading is what moves atime.

```text
== 1. steamcmd orchestration in shipped code
  no shipped source file invokes steamcmd
== 2. Steam credential handling
  no shipped source file reads, stores or relays Steam credentials
== 3. driving the Steam client by input or process control
  no shipped source file simulates input to or controls the Steam client
== 4. discovery leaves a Steam library byte-for-byte unchanged
  both libraries unchanged after list, fingerprint and verify
  discovery read appmanifest ACFs from both library folders
  rerun verification reproduces the build identity
  discovery wrote nothing except the requested fingerprint files
== 5. steamcmd named outside the legal and research record
  steamcmd appears only where the prohibition is recorded

STEAM-AUTOMATION: pass - discovery is read-only, no account interaction
```

A gate that has only ever been green is indistinguishable from a gate that cannot
fail, so `gate-selftest.sh` plants each prohibited flow in a synthetic repository
and requires rejection, plus one clean repository requiring a pass:

```text
ok: steamcmd-orchestration
ok: credential-surface
ok: client-process-control
ok: discovery-writes
ok: undocumented-steamcmd-plan
ok: clean-repository
```

Both run in CI. The synthetic library means no Steam installation is required.

Check 5 also proved itself outside the selftest, on this task's own work: amending
doc 14 and doc 16 to record the prohibition made both name `steamcmd`, and the
gate failed until each was consciously added to the allowlist. That is the
intended friction — a document may name the flow only when someone has decided it
records the prohibition rather than proposing it.

**The gate's own first version was green for the wrong reason**, and it is worth
recording because the failure mode is general. Checks 1–3 scan `git ls-files`,
and `gate-selftest.sh` necessarily contains every prohibited string as a fixture.
While the selftest was still untracked it was invisible to the scan, so the gate
passed; the first commit made it tracked and all three checks immediately
reported it. The exclusion is now by directory — this directory is the
enforcement machinery, and both files in it have to be able to name what they
enforce — rather than by a single filename that stops covering new files as they
are added. A green gate on a tree where the relevant file is untracked is not
evidence, and nothing about the output distinguished the two cases.

## The correction: EPIC-013 specified the prohibited product

[Doc 19](../../../docs/docs/19_MVP_EPICS_AND_BACKLOG.md) EPIC-013 — the first
storefront adapter, the epic the MVP would have been built from — read:

> **Outcome:** Ownership, install, update, repair, authentication, and build
> identity work for one storefront.

with stories for `installation/library discovery`, `launcher update` and
`verify/repair`, and this acceptance criterion:

> - no credential interception;

Every one of those is on the verdict's do-not-ship list. Worse, the acceptance
criterion is precisely the reasoning the verdict anticipates and refuses:

> The brief correctly identifies credential interception as something Alloy
> avoids, but lack of credential interception does not resolve the separate
> automation language.

So the epic would have passed its own acceptance while shipping the thing item 6
prohibits. The epic also cites INS-008, which already says the runtime "SHOULD
coexist with storefront ownership, verification, and update workflows rather than
copying or bypassing them" — the epic contradicted the requirement it claimed to
implement, and had done so since before the verdict existed.

EPIC-013 is now restated to read-only discovery, build identity, update
*detection*, and user-initiated handoff, with acceptance that names the automation
clause rather than the credential argument.

## Documents corrected

| Document | Change |
| --- | --- |
| doc 19, EPIC-013 | outcome, stories and acceptance restated to the permitted posture |
| doc 14, D-019 | status marked scope-narrowed; the decision record now carries the item 6 limits |
| doc 16, SPIKE-STORE-001 | closure note carries the narrowing, and records that lab `steamcmd` is still open rather than mitigated |
| doc 18 §9 | evidence paragraph pointing at the gate that enforces it |
| SPIKE-STORE-001 findings §5 | the `steamcmd` depot re-verification open item withdrawn — it scheduled work we have decided not to do |
| doc 11 §3 | the storefront workstream owned "install/auth/update adapters"; it now owns discovery, handoff and build identity |
| doc 04 §7 | `RuntimeDaemon` was to "coordinate storefront installation and updates"; it now sequences work *around* storefront-performed installs and observes them through local manifests |
| doc 04 §18.3 | the UI-automation carve-out reserved simulated input "for the compatibility lab", which read as permission to drive the Steam client there. It now states that the reservation is not an exemption from a storefront's terms, and routes the lab case to the open §4.C question — flagged, not decided |
| doc 07 §18 | update-detection objective said "where automation allows", a hedge written before the answer existed; it now names the permitted route (local manifest polling, not automated service queries) |

Two of these are worth separating from the rest. Doc 04 §18.3's lab carve-out and
doc 11's workstream charter were not sloppy wording — they were live permissions.
One read as authorising simulated input against a storefront client anywhere in
the lab, and the other made "install/auth/update adapters" somebody's job
description. Note the asymmetry in how they are fixed: doc 11's is a product
scope statement and is corrected outright, while doc 04's reaches into lab
practice, which this issue explicitly holds open — so that one is narrowed to a
warning and a pointer, and the founder still owns the decision.

## Judgement calls, recorded rather than buried

- **`steamcmd` against our own entitled lab accounts is still open.** It is not
  cleared by this task. Doc 18 §8 governs it and SSA §4.C still reaches it; the
  gate deliberately blocks it from shipped code without pretending the lab
  question is answered.
- **Doc 03 §9.2's player-visible step "Opening Steam / Epic / other storefront"
  is left as-is.** Starting the official client after the player presses Play is
  a user-initiated launch, which §9 permits; it is not simulated input or process
  control, which is what the verdict prohibits. Flagged here rather than silently
  edited, because it is the closest call in the corpus.
- **The gate excludes documentation from its code scan on purpose.** Doc 18, the
  verdict and the research record have to name the prohibited flows in order to
  prohibit them. Check 5 handles documents with an explicit allowlist, so a new
  document proposing a `steamcmd` flow fails while the legal record stays legal.

## What this does not close

Item 6 remains a **pre-counsel** risk assessment, not counsel's answer. This
result constrains the v1 design and proves the implementation matches it; it does
not discharge D10, and issue #13 stays open. Anything beyond read-only discovery
and user-driven client actions still needs Valve's written permission.
