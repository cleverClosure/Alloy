<!-- Author: Timur Isaev -->

# Issue 177 milestone 1: canonical v2 format

The new explicit `compile-v2` and `inspect-v2` API/CLI implement the
[ALLOYP02 contract](../SNAPSHOT_V2.md). The historical ALLOYP01 encoder and frozen
profile-compiler oracle are unchanged. The runtime v2 reader rejects v1 by name.

The format bounds allocation to 1024 entries / 7,651,424 bytes, represents field
absence separately from empty tables, and covers complete header and entry bytes
with SHA-256. The trusted caller's expected complete-file digest is a separate
binding. Parsing verifies integrity and every canonical field before returning
policy data. Source input normalizes only documented case/order conventions.

Validation on this Mac:

- Nine Swift tests passed, including mutations at every byte of a valid file.
- 196 malformed inputs each terminated two separate reader processes: 392 named
  failures, zero import markers. Native parsing used ASan and UBSan.
- Checksums were recomputed for structural negatives, so the integrity check
  could not conceal layout, padding, presence, route and environment defects.
- The unchanged profile-compiler suite passed 58 tests across 13 suites, including
  its frozen v1 oracle and 512 seeded full-pipeline clean/mutated pairs.
- Repository lint passed. `snapshot-v2-controls` is registered in the fast tier;
  the existing full-tier policy tests and guest proof are retained.

The native process marker proves the parser caller boundary only. This milestone
does not claim Wine enforcement or guest execution; those are the next
milestones. The Wine patch will embed the same validated native header, and the
runtime proof will require failure before the guest DLL import marker.

## Hosted scan budget

The first hosted CI run passed all selected tests. CodeQL actions, Python and C/C++
also passed; Swift hit the job's 30-minute wall-clock limit while starting the
last package, after the preceding packages built successfully. No compiler
error was reported. Run `37342536831` preserves that failed attempt. The Swift
job budget is now 45 minutes; all other jobs retain 30 minutes, the same standard
public runner, and the complete first-party package scan. This is a finite
time-budget adjustment needed to finish the required analysis, not a skipped
package, suppressed finding or successful scan claim.
