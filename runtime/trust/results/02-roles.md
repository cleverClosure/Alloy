# Role and persistence controls

Author: Timur Isaev

6 October 2026, Apple Silicon, local offline test corpus. Controls cover valid
pinned bootstrap, all four update roles, target authorization, and reopening
persisted state. Each attack is paired with acceptance of valid metadata.

| Attack | Required failure |
| --- | --- |
| Replay each role's older version | `rollback(role)` |
| Changed content at the same version; mixed snapshot | `mixAndMatch` |
| Wrong signer / too few distinct signatures | `belowThreshold` |
| Cross-scope metadata | `wrongRole` |
| Expired metadata in each update role | `expired(role)` |
| Withheld timestamp past expiry | `expired(timestamp)` |
| Clock reversal after observed expiry | `freeze` |
| Wrong pin or root with shared role keys | `invalidRoot` |
| Unlisted artifact | `unauthorizedTarget` |
| Changed envelope bytes for an allowed payload | `mixAndMatch` |
| Missing/corrupt local state | state/read failure, no reset |
| Verifier retained after transaction | `state(verification transaction ended)` |

Repeated signing on this SDK can yield different signature bytes. The tests
retain signed artifacts exactly; a recreated signature correctly invalidates
whole-envelope references. This does not change canonical payload digests.
