# Milestone 3 — settings and disposable state

Author: Timur Isaev

Versioned settings retain the old tree before update/reset, detect external
drift, and couple new fingerprints/history to the tree-swap recovery journal.
Cache selection hashes runtime, provider and compatibility identities. Scratch
expiry and cache invalidation have typed journals that cannot designate saves.

Controls cover exact quota acceptance and overrun refusal in all four state
categories, settings drift/reset/history, independent runtime and provider cache
changes, seven settings fault boundaries, six cache boundaries and four scratch
boundaries. Each state operation verifies the populated save tree is unchanged.
The final milestone supplies real process-death supervision in addition to these
deterministic thrown-fault controls.
