# Milestone 2: scheduling and process-death controls

Author: Timur Isaev

The scheduler runs actual v1 and v2 subjects through the same durable queue and
v2 evidence capture. The v1 control returns the committed 344,064 channel sum;
the native probe returns its independently known answer 42. Observations are
validated against stored stdout/frame bytes and stable execution digests.

Real concurrent timing workers have disjoint measured begin/end intervals. A
planted overlap makes the independent interval detector fail. Shared functional
workers both enter an actual two-process barrier, proving shared admission is
not accidentally serialized.

The scheduler is killed while its child writes a heartbeat. The worker observes
parent EOF, stops the child, writes INTERRUPTED evidence, releases its inherited
lock, and admits a subsequent clean job. A separate kill after durable claim and
before worker spawn recovers one interrupted attempt, with no fabricated evidence
or automatic retry. Queue priority/cancellation/deadline persistence, running
cancellation/deadline, step timeout, output cap, input mismatch before execution,
corrupt queue identity and the public host-lock CLI have positive/negative controls.

Run the bounded proof with:

```sh
python3 -B -m unittest discover -s tools/lab/tests -p 'test_scheduler.py' -v
```

No Wine guest or shared runtime is used in this milestone. The scheduler's lock
is cooperative; the [contract](../schemas/SCHEDULER.md) specifies child ownership,
parent-loss cleanup, remaining worker-loss limits and how other heavy work joins.
