<!-- Author: Timur Isaev -->

# Synthetic native capture

`NativeCapture` observes the first-party `AlloyDiagnosticsSubject`, locally on
macOS, and tags each returned report with the supplied M1 correlation identity.
It is a synthetic capture mechanism, not a game/daemon watchdog or a sandbox
for arbitrary executables. Xcode LLDB and the macOS `sample` command are the
only external tools; no package dependency, network call, Wine guest, or shared
runtime is involved.

## Known causes and negative controls

The crash subject calls `fatalError("DIAG_SEEDED_NATIVE_CRASH")` inside the
non-inlined `seededNativeCrash()` function. LLDB catches the actual native stop,
collects all thread backtraces, and kills the stopped inferior. A report requires
the real stop marker, seeded cause, function name, and frame output; the test
also requires the source-file location. The clean control exits successfully
and produces no crash report.

The hang subject writes readiness and waits on a zero-count semaphore in
`seededNativeDeadlock`. `sample` observes the real process for one second. A
report requires both that function and `semaphore_wait` in the snapshot. The
fast control exits without becoming ready and produces no snapshot. A separate
ready-then-exit-23 control must fail as `subject-exit`; failure after readiness
must never become a clean fast result. This is a known blocked synthetic thread,
not a claim to infer arbitrary application deadlock causes from one stack.

## Deadlines and resource limits

The capture deadline defaults to **10 seconds**, with valid explicit values
from 0.1 through 20 seconds. Monotonic uptime starts before launch. Readiness,
tool execution, and pipe EOF use the original remaining deadline; an inherited
pipe does not receive a new drain allowance after the direct tool exits.
The synchronous nonblocking reader retains at most **1,048,576 bytes** across
stdout and stderr and reads at most 16 chunks of 4,096 bytes before checking
processes and time again. There is no detached reader thread to leak.

Teardown has a separate **0.5-second budget per owned process family**. A crash
capture owns one family, so its execution plus teardown budget is the selected
deadline + 0.5 seconds. Hang capture owns the subject and sampler families, so
its maximum aggregate teardown allowance is 1 second beyond the selected
deadline. Polls sleep 5ms; these are checked software budgets subject to host
scheduling and syscall latency, not hard real-time guarantees. A cleanup budget
failure is reported as `capture-cleanup-deadline`, never as successful capture.
Successful report timing includes cleanup; tests also time the external call.

The sampler file is rejected before loading if it exceeds 1,048,576 bytes.
That is an accepted-artifact size limit, not a quota on the tool's temporary
disk writes. Temporary snapshot/readiness files are removed on both success
and failure.

## Owned-process cleanup and its limits

Foundation starts the direct process in a distinct process group on this host,
but LLDB's debugserver and inferior use other process groups/sessions. Killing
only the debugger, or only its group, is therefore insufficient.

`OwnedProcessFamily` polls the macOS child-process API and records at most 128
observed identities, each containing PID and kernel process-start time. It
continues observing discovered children after a direct parent exits. Before a
signal it rechecks the full identity, kills verified descendants before the
debugger, and reaps its direct child. Zombie descendants are already stopped
and cannot continue a heartbeat. Query/census overflow and teardown failures
are explicit errors. If the initial identity query is unavailable while the
direct child is running, capture never begins: the immediate launch-failure
path kills and reaps Foundation's owned direct child and reports
`capture-identity-unavailable`.

This is a bounded census for these cooperative synthetic tools. It does not
intercept an adversarial child that forks and reparents entirely between polls,
and it is not a general guarantee against process-tree escape. The claim is
supported by the exact LLDB/native controls below, not by group ownership alone.

## Executable controls

```sh
swift build --package-path spikes/DIAG-001/prototype
swift test --package-path spikes/DIAG-001/prototype --filter CaptureTests
```

The eight capture tests cover:

- An actual symbolicated crash and clean-exit negative control.
- A sampled blocked thread and fast-exit negative control.
- A 100ms direct-tool deadline and invalid executable rejection.
- The ready-then-nonzero failure path.
- A real 1,048,577-byte flood that must fire the byte-cap error.
- An injected unavailable initial identity query: the capture body must not
  execute, and the actual direct child must be killed and reaped.
- A parent that exits while its child retains the output pipe: the original
  500ms deadline must fire, and the descendant must be removed.
- LLDB launching a heartbeat inferior in its real separate process group:
  the three-second debugger timeout must remove that inferior too.

Both descendant controls require a recorded PID and a heartbeat counter greater
than zero, assert that the process is no longer live after return, and verify
the heartbeat file remains byte-identical after another 100ms. Thus a control
that never launched cannot pass as successful cleanup.
