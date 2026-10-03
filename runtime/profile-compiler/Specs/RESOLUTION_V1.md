# Local resolver, version 1

Author: Timur Isaev

This implementation follows doc 05 sections 6, 9, and 10.3. It is a local,
test-key compiler, not a control-plane release authority. Published schemas
are unchanged. Selection is pure given signed candidates, observed identities,
host capabilities, explicit client eligibility, and a caller-supplied clock.

## Inputs and trust

A `ProfileCandidate` verifies profile, manifest, and local release-metadata
envelopes before decoding them. The metadata binds the exact profile digest
and approved certification level. Candidate construction also checks runtime
generation equality and certification expiry. Selection rechecks every
envelope and certification expiry, including previously verified candidates.

`CandidateMetadata` is an explicitly local, independently signed companion
format because the approved profile schema contains no release ring, alias,
denied-build, or client-eligibility fields. It records profile digest, ring,
approved level, game/launcher alias digests, denied OS builds, required host
features, optional eligible client IDs, and optional minimum client version.
Its decoder rejects unknown fields. This format must not be presented as an
approved control-plane API. The TEST-ONLY trust caveat applies to every field.

An alias authenticates the digest of the **entire** observed build identity:
ID, version, manifest, and normalized files with digest/size/PE timestamp.
Changing any dimension invalidates the alias. Profile digest binding also
binds its certification evidence. Game and launcher aliases are separate.
File paths fold case and separators, remove `.` components, and reject `..`,
controls, empty paths, and ambiguous duplicate paths. This normalization is
only for identity matching; it is not filesystem authorization or a symlink
defense. Runtime filesystem enforcement remains a separate component.

## Profile selection

Candidates must match the canonical game and storefront binding, all required
game and launcher selectors (or an explicit signed alias), host and manifest
requirements, ring, client cohort, and minimum client version. Denied OS builds
and quarantined rings are always excluded. Missing manifest activation means
development, never stable. Empty build selectors that lack a discriminating
version, manifest, or file digest fail closed even if structurally valid.

The five tie-breakers run in this order:

1. Greatest selector specificity. V1 counts independently constrained version,
   manifest, file digest, file size, PE timestamp, launcher equivalents, host
   version bounds, allowed-build list, GPU list, memory list, and the matching
   storefront's branch. Duplicate file selectors are rejected. Collection
   cardinality does not add specificity. Architecture and canonical identity
   are already mandatory for every candidate.
2. Highest approved certification level.
3. Highest revision **within each logical profile family**; revision numbers
   from unrelated families are never compared.
4. Explicit `supersedes` names of other profile families, only from an equal
   or higher trust ring. Cycles leave a conflict.
5. Stable over canary for a non-canary client explicitly eligible for both.
   Canary clients get no implicit preference absent an earlier tie-breaker.

Any remaining ambiguity returns `conflict`, with no selected candidate;
`requireSelected()` throws. Sorting by arrival order cannot resolve a conflict.
Exact duplicate candidates are deduplicated. `stale` requires explicit local
history plus a game-build mismatch; absent history yields `unknown`. Neither
outcome authorizes launch. Successful signed alias matches return
`compatibleAlias`; other successful matches return `exact`.

## Process selection

Every match dimension is conjunctive. Executable digest precedes path/product
rules; parent-plus-child relationships precede generic child rules; priority
breaks ties only within equal specificity. Equal-precedence assignments must
agree on the complete effective policy or fail closed. Matching network deny,
publisher-only restrictions, and disabled DLL routes compose across priorities.
Rule IDs are unique; returned winning IDs are sorted.

Inheritance is per field and explicit. `inherit` requires a supplied resolved
parent whose rule ID matches the process's parent identity. An absent field
uses the conservative default: the profile's default CPU/graphics providers,
conservative synchronization, denied network, crash-only diagnostics, and no
extra environment, services, working directory, feature mask, or DLL routes.
Unknown processes get this same default without inheriting parent access.

Path globs support `?`, `*` within a directory, and recursive `**`; `**/` also
matches zero directories. A dynamic-programming matcher bounds work even for
adversarial globs. Command-line regexes use a bounded subset: at most 256
bytes, one repetition operator, and no groups, alternation, counted repetition,
or backreferences; command lines are at most 4096 bytes. Unsupported regexes
are rejected even on otherwise nonmatching rules. This explicit limit avoids
unbounded regular-expression backtracking in a startup compiler.

## Evidence and next layers

Committed JSON goldens cover each of the five profile and seven process rules,
with a paired counterfactual that changes the expected result. Each pair runs
ten times with reversed candidate order. Deliberately disabling each rule
makes its golden test fail; every defect is restored before the final run.
Additional controls cover all match dimensions, alias tampering, expiry,
cross-family revisions, lower-trust supersession, cycles, and parent identity.

This milestone chooses policy. Snapshot field coverage and local launch
artifact validation are added by milestones 4 and 5; selection alone does not
mean the current Wine v1 snapshot can enforce every selected field.
