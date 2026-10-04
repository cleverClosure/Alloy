<!-- Author: Timur Isaev -->

# LAB-001 scenario v1

This local Python-stdlib prototype invokes a synthetic native subject. It needs
no Wine, purchased title, external package, signing account, or hosted runner.
Each milestone for issue #77 is a separate PR; this is the subject/format slice.

`scenario-v1.json` is the versioned invocation and capture contract. The command
is an argument array, never a shell string. `{python}` selects the running Python
interpreter; `{root}` is the scenario directory; `{output}` is a fresh capture
directory; `{mode}` is clean, seeded, hang, or error. The format intentionally
supports only this one subject and four 16×16 P6 frames. A future real-title
adapter requires a separate format revision. Unknown fields, versions, types,
and placeholders are errors. The timeout is in seconds, bounded to 0.01–60.

For frame `f` (0–3), pixel `(x,y)` (0–15), the RGB bytes are `(16x,16y,64f)`.
The header is the literal ASCII `P6\n16 16\n255\n`; each file is 781 bytes.
There are 1,024 pixels and their channel sum is 344,064. Seeded mode changes
only the first frame's first red byte from zero to one, making the sum 344,065.
Committed SHA-256 values bind all four complete image files in each mode.
These counters describe generated image data, not GPU or game frame timing.

`test_subject.py` runs the subject directly five times clean and once seeded,
checks every pixel with an independent offset-based formula, checks the literal
digests, and rejects malformed scenarios. It does not call the subject renderer
to compute its oracle.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s spikes/LAB-001 -p 'test_subject.py' -v
python3 spikes/LAB-001/subject.py --output /tmp/lab-subject --mode clean
```

The following slices add lifecycle/resource capture, validated evidence,
calibrated variance, mandatory comparator controls, and the closing spike proof.
