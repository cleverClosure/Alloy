# Local compatibility laboratory

Author: Timur Isaev

`tools/lab/` is the Mac-side lab system for issue #180. It uses Python's standard
library. Existing [LAB-001 results](../../spikes/LAB-001/results/) remain at their
original URLs and the prototype remains executable. The v2 adapter preserves its
original scenario, known-answer oracle, timeout and original-byte digest.

```sh
python3 tools/lab/lab.py validate-scenario spikes/LAB-001/scenario-v1.json
python3 tools/lab/lab.py migrate-v1 spikes/LAB-001/scenario-v1.json > /private/tmp/scenario-v2.json
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/lab/tests -v
```

The [v2 contracts](schemas/CONTRACTS.md) define scenarios and evidence. This first
milestone delivers validation and migration. Subsequent milestones add the durable
scheduler/resource lock, evidence store/comparison/retries, then the guest proof
and submission handoff. No CLI command in this milestone launches a guest.
