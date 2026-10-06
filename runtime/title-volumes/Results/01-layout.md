# Milestone 1 — layout and ownership

Author: Timur Isaev

The package implements title-bound save/settings records and separate cache and
session records with durable metadata, restrictive permissions and quotas.
Native shared session leases prevent expiry from deleting active scratch.

Controls cover restart identity, cross-title separation, exact quota acceptance
and refusal, an externally planted overrun, traversal, symlink and hard-link
escapes, case aliases, live/expired session leases, and corrupt/missing registry
refusal. Every destructive/path attack checks an unchanged save control.

The no-symlink root policy intentionally refuses macOS's `/tmp` and `/var`
aliases. Fixtures use canonical `/private/tmp` roots. Production consumers must
pass a canonical host-owned root and enforce the guest write boundary described
in the layout contract. Save snapshots and the full operation kill matrix are
delivered by the subsequent milestones.
