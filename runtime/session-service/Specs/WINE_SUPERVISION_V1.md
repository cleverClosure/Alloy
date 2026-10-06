<!-- Author: Timur Isaev -->

# Synthetic Wine process supervision

This development driver uses the pinned wineserver's full protocol trace as its
Windows-process inventory. It does not infer process counts from periodic PID
samples. Every successful `new_process` and `init_first_thread` is retained,
including a child that exits before the next observation. Creation records have
a session-scoped ordinal; Wine PIDs may be reused without aliasing that identity.
The trace's server-start epoch must remain consistent. Parent links come from the
creating server thread; unresolved parentage stays unresolved.

The fixed session agent first starts a copy of itself as a blocked server gate.
Its kernel birth identity receives the generation lease, and ownership is written
durably before the gate can exec the fixed `server/wineserver`. EOF before that
point exits without starting a server. Exec preserves the leased process identity.
The server runs in the foreground, persistently, for exactly this private prefix.
It pins the generation while the agent is unavailable; the agent's separate lease
covers cleanup after server failure. No guest starts before the server lease and
ownership record exist.

## Identity and health

`WineSessionSnapshot.processes` exposes each creation's stable identifier,
Wine PID, image path, parent identifier where available, Unix PID where initialized,
observed kernel birth identity where available, classification and expected policy
ID. `known` means an image path bound by the specification; `runtime` identifies
Wine's Windows-directory programs; other children are explicitly `unknown` and
name the restricted default. The expected policy ID is not an independent claim
that enforcement succeeded: the end-to-end guest/provider observations prove that.

A process too short-lived for native observation remains in the complete trace
inventory. Its historical Unix PID never becomes permission to signal whatever
currently owns that PID. Live native observations additionally match the kernel's
executable path and original WINEPREFIX to this exact loader and prefix, and check
the same birth identity before and after reading. If macOS omits this information,
no native kill authority is inferred. Directly spawned children retain their
captured birth identities.

The monitor checks session/server lease records and exact holder liveness once a
second, and bounds guest output, trace bytes and process count. Lease issuance and
initial runtime verification use the content-store API. Health reads the issued
private lease record and compares the complete record; it does not invoke catalog
rebuilding, which revalidates large runtime files and would delay stop handling.
Limits are 128 creation records, 16 MiB of server trace, 1 MiB of guest output,
128 recent correlated events, and the requested 1–120 second guest watchdog.
Event sequence numbers remain monotonic when older events leave the bounded ring.
`healthChecks` counts completed checks.

## Stop and recovery

The explicit synthetic guest contract permits cooperative stop through a `stop`
file on T:. The service writes that request and allows one second for cooperation,
then requests prefix-scoped `wineserver -k`. A bounded wait is followed by SIGKILL
only for exact owned native birth identities that are still live. Cleanup never
spawns a Wine client that could start a replacement server. A launcher exiting
does not finish the session while its game or unknown children remain alive.

Complete trace evidence and native death checks precede successful terminal state.
A forced native exit can complete a retained creation only when that exact native
identity has been observed dead. Missing, malformed or truncated trace evidence
cannot be reported as a successful complete inventory. Diagnostic write failures
must not prevent attempts to stop the owned tree.

On service restart, existing sessions receive persisted stop intent. Agents also
observe control-pipe EOF. A maintenance worker reconciles a dead agent from its
persisted server ownership and trace, stops the prefix, verifies owned identities
are dead, and releases leases. It never reconstructs signal authority from a
historical Unix PID. Reconciled sessions report `SESSION_INTERRUPTED`; watchdog
expiry reports `SESSION_WATCHDOG`. Failed cleanup reports
`SESSION_CLEANUP_FAILED`, and incomplete inventory reports
`PROCESS_INVENTORY_INCOMPLETE`. Prefix bootstrap records permit scoped cleanup if
an agent dies before its cached environment is ready; normal bootstrap commands
also observe cancellation.

These are synthetic development sessions. The drive namespace is not a host
filesystem authorization boundary, and this protocol makes no storefront or
production-game support claim.

## Launch admission

`launch.game` persists a pending launch and returns `STARTING` before expensive
content-store work. The pending record contains the captured agent birth identity,
canonical preview and request correlation. The fixed helper is blocked on stdin;
no Wine process exists yet. A serial preparation worker verifies the active
reference and acquires the generation lease through the content-store API. It
compares the returned holder with that captured identity, persists the complete
request, and only then opens the helper's gate. Stop and gate release share a short
lock; runtime hashing never holds that lock. Duplicate launch requests reuse the
same pending session. Pending launches count against the live-session limit.

Stop closes the pending gate. Service death closes it through EOF; a later client
observes `INTERRUPTED` once that captured helper is dead. A lease created just
before service death remains tied to the now-dead holder and is safely prunable.
Recovery never promotes a pending helper's PID to a different process identity.
The proof includes stop and service restart during deliberately delayed admission,
with no Wine/server output permitted, and caps the launch request itself at five
seconds. All runtime and payload checks still precede guest execution.

Pending nonterminal snapshots contain no events. The agent starts the event
sequence once execution preparation begins; an admission failure instead owns
its sole terminal event. This prevents reusing sequence 1 for different pending
and agent events across polling responses.
