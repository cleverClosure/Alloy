# STORE-001 result 04 — the first sweep missed four places, and the gate was exempting the worst one

**Author:** Tim Isaev
**Date:** 25 July 2026
**Scope:** counsel checklist item 6, Steam automation (issue #25, follow-up to [result 03](2026-07-25-03-steam-readonly-conformance.md))
**Gate:** `spikes/STORE-001/steam-readonly/steam-automation-gate.sh`

## Verdict

**The work in result 03 was incomplete and the issue was closed too early.** A
second sweep of the same corpus found four more places the v1 design described
prohibited Steam interaction, including the single most direct contradiction of
item 6 anywhere in the repository.

## What was missed

| Location | Text | Prohibited item |
| --- | --- | --- |
| `SPIKE-LEGAL-001-preliminary-findings.md` §2 | "Launch official client; read local `appmanifest_*.acf`; **steamcmd fine**; §4.C 'Automation' text is the residual gray" | background SteamCMD |
| doc 04 §18.1 | adapter contract lists "**Authenticate** or hand off to official client"; adapters may use "**command-line contracts**"; screen scraping permitted as a last resort | automatic login; SteamCMD; driving the client |
| doc 04 §18.6 | "Native integrations **store refresh tokens** in Keychain" — no storefront carve-out | storing or relaying credentials |
| ADR-0011 §6 | cites "the **no-UI-automation rule** in the architecture" | a rule that does not exist as stated |

The preliminary-findings entry is the serious one. It is a flat statement that
`steamcmd` is acceptable, written the day before the assessment said the
opposite, sitting in a document an engineer would reasonably implement from.
Every other superseded position in that file was corrected or banner-marked; this
one was not.

## Why the first sweep missed them

The first pass grepped for action verbs and required a storefront word on the
same line:

```text
grep -rniE "(install|update|repair|...)" docs/docs/*.md | grep -iE "storefront|steam|launcher"
```

Doc 04 §18 is a section *about* storefronts, so its individual lines do not
repeat the word. "Authenticate or hand off to official client" contains neither
"steam" nor "storefront". The filter that made the output readable is exactly the
filter that hid the section most likely to contain violations. A section-scoped
read would have found them; a line-scoped grep could not.

## The gate was exempting the worst finding

Check 5 fails any document naming `steamcmd` outside an allowlist of files whose
job is to record the prohibition. `SPIKE-LEGAL-001-preliminary-findings.md` is on
that allowlist. So the gate shipped in #54 **passed a file that said "steamcmd
fine"** — the allowlist granted permission to mention, and never asked whether
what was said was still true.

Check 6 now closes that. It is worth recording how it got there, because the
first version was wrong in an instructive way:

1. **First attempt** — require every allowlisted document naming `steamcmd` to
   also contain a correction word somewhere in the file (`superseded`,
   `withdrawn`, `prohibit`, ...). Run against the real pre-fix file, it
   **passed** — because "prohibited" appears in an unrelated row about GPTK
   redistribution. A whole-file keyword search exempts a file for words that have
   nothing to do with the claim.
2. **Second attempt** — require the correction on the same line as the mention.
   Too strict: the verdict quotes the prohibition verbatim across several lines,
   and would have failed for recording it accurately.
3. **Shipped** — test the one property that is actually decidable. A research
   *findings* document records a conclusion that can later be overturned, so one
   that still names `steamcmd` must carry a `Superseded` banner. Prohibition
   sources such as doc 18 and the verdict are out of scope; being the prohibition
   is their job.

Deciding from prose whether a paragraph permits or forbids something is not
something grep can do, and pretending otherwise produces a check that is green
for reasons unrelated to what it claims to test. Narrowing it to a staleness
property on research records gives up coverage and gains a check that means what
it says.

Validated against the real defect rather than only a fixture — the gate run
against the pre-fix file:

```text
== 6. superseded research records say so
  FAIL: a research record names steamcmd with no supersession banner:
        docs/research/SPIKE-LEGAL-001-preliminary-findings.md
```

`gate-selftest.sh` gains a seventh case covering the same shape.

## Corrections made

| Document | Change |
| --- | --- |
| `SPIKE-LEGAL-001-preliminary-findings.md` | supersession banner added, naming the four positions the assessment overturned; the Steam row's "steamcmd fine" struck and replaced |
| doc 04 §18.1 | adapter contract is handoff-only; command-line contracts allowed only where a storefront's terms authorise them, and `steamcmd` named as prohibited; screen scraping never applied to a storefront client |
| doc 04 §18.6 | token storage scoped to storefronts with an official integration; Steam carve-out stating no credential, token or session artefact is stored or relayed |
| ADR-0011 §6 | the phantom "no-UI-automation rule" replaced with what the architecture actually says, including that the lab allowance exists and is why the storefront-client exclusion is stated separately |
| doc 06 §6.2 | install/repair operations scoped to Alloy's own runtime generations; Alloy does not invoke a storefront's verify-or-repair on the user's behalf |

## Process note

Issue #25 was closed when its PR merged and reopened when this sweep landed. The
Done-when — "the v1 design contains no automated Steam account or download
interaction" — was not met at the time of closing, and a Done card asserting
otherwise is worse than an open one.
