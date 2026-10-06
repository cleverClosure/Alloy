# Milestone 1: scenario and evidence contracts

Author: Timur Isaev

Seven bounded contract tests pass. Positive controls use an independently authored
v2 fixture and actual v1 bytes. Negative controls reject malformed paths/templates,
duplicate/nonfinite JSON, missing identities, changed runtime/subject/inputs,
wrong lock claims, absent observations, false completion, corrupt artifact bytes,
symlinks and re-sealed observations that disagree with captured JSON.

Migration retains the original v1 definition and source digest, its 344,064 clean
pixel-sum oracle, four frame hashes, three counters and timeout. Serializing and
re-reading v2 is lossless. The validator CLI produces identical output on repeated
validation and returns a nonzero status for corrupt evidence. These are contract
and detector controls, not evidence of guest execution or certification.
