<!-- Author: Timur Isaev -->

# Session environment proof

Milestone 1 of #181, 6 October 2026. The
[recorded result](2026-10-06-environment.json) contains two independent cold-cache
runs against #177's verified runtime tree
`sha256:6fbeb915a7bb987b060d14ef6060a510ce9632a817c123799547d4bae9fd6610`.
Both yielded template digest
`sha256:88f45970897ee7bcc1803529f2065847115d0a20d87a607728325e4f35613118`
and construction digest
`sha256:5b8ce98c74e9fed1c7a09dbfaee0176d7fcfc599a9b3c39cd7794ed9f10c2a15`.

Each run initialized one template, copied it twice, started two distinct
foreground wineservers and stopped only the first. The second remained live.
Final cleanup left neither exact PID/kernel-start identity alive. Materializer
verification matched before and after both runs. Raw private artifacts are at
`/private/tmp/alloy-181-cold-pair-settled/{1,2}`.

The cold-cache comparison first failed on generated registry timestamps/IDs and
then on incomplete COM registration. The implementation now uses deterministic
fresh-template metadata and waits for registration children with `wineserver -w`
before rebooting to settle pending DLL replacement. The proof compares complete
template digests; it does not exclude different registry keys to obtain a pass.

Package controls cover copied-file isolation, persistent saved bytes, C/G/S/T
links, removed Z:/host user-folder links, relative internal links, the scrubbed
environment, tampered caches, aliased cache roots, deterministic fresh hive
metadata and refusal of pending updates. Registry self-tests and repository lint
pass. This milestone does not start a guest session through XPC; policy transport,
supervision and final end-to-end evidence belong to the following milestones.
