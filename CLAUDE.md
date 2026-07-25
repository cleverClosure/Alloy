# Alloy — agent working agreement

Repo-local instructions. `TASKS.md` is the full board protocol; this file is the
short list of things that have actually gone wrong.

## Claiming a task

**Always claim with the script, never by hand:**

```sh
scripts/next-task.sh                 # show what is eligible
scripts/next-task.sh --claim claude  # claim the top task (or: codex)
```

`--claim` assigns the account, **sets the board's `Agent` field**, moves the card
to In Progress, and comments the agent name. Doing those steps by hand is how the
`Agent` field gets left unset — the board then shows a task In Progress with no
owner, and the other agent cannot tell whether it is free.

If a task is taken outside the normal flow (founder hands it over directly, or
it is picked up mid-flight from another agent), set the field explicitly:

```sh
PID=$(gh project view 1 --owner cleverClosure --format json -q '.id')
FID=$(gh project field-list 1 --owner cleverClosure --format json -q '.fields[]|select(.name=="Agent")|.id')
OPT=$(gh project field-list 1 --owner cleverClosure --format json -q '.fields[]|select(.name=="Agent")|.options[]|select(.name=="claude")|.id')
IID=$(gh project item-list 1 --owner cleverClosure --format json -q '.items[]|select(.content.number==NN)|.id')
gh project item-edit --id "$IID" --project-id "$PID" --field-id "$FID" --single-select-option-id "$OPT"
```

Verify with `gh project item-list 1 --owner cleverClosure --format json -q
'.items[]|select(.content.number==NN)|{status,agent}'`. Note the field is `.agent`
at the item level, **not** `.projectItems[].agent` — the latter silently reports
`unset` even when the field is set correctly.

Board status and `Agent` are set on **claim**, not at the end. A task in progress
with no agent is indistinguishable from an abandoned one.

## Not clashing with the other agent

Two agents share this repo and one runtime. Before building into a shared tree,
check whether the other agent is mid-run:

```sh
ps aux | rg '[A]lloy/spikes/WINE-001/work/build-2'
```

- `spikes/WINE-001/work/build-2` and `third_party/src/{fex,wine}` are **shared**.
  Building into them changes what the other agent's next run loads.
- Performance tasks are the sharp case: swapping FEX or `ntdll` under a live
  measurement corrupts its numbers, and CPU contention from a heavy run does too.
  Wait, or work in an isolated copy.
- Leave shared source trees checked out on their **live** branch
  (`alloy/spike-wine-001`, the current `alloy/task-*` FEX tip) when done. Leaving
  them on a personal branch means the other agent silently builds your code.
- If you must build into `build-2`, back the artifact up first and restore it,
  and verify the restore by hash rather than assuming the build succeeded.

## Measurement

Every counter in this tree that has misled someone was rate-limited: first N,
then every 100,000th. That is a sampler, not a count, and reading it as a count
has now cost three separate wrong conclusions (CPU-001 results 17 and 19, #30).

Before quoting any number, make the instrument fail on purpose: a guest whose
answer is known by construction, and a negative control that must report zero.
A counter that has never been observed to fire reports zero for "nothing
happened" and for "the counter is dead" with equal confidence.

## Runtime gotchas that cost sessions

- **Wine loads its own builtin `libarm64ecfex` before the prefix's system32
  copy.** Installing into `<prefix>/drive_c/windows/system32` does nothing;
  `WINEDLLPATH` and `WINEDLLOVERRIDES` do not redirect it either, because Wow64
  loads the emulator DLL directly. The build-tree copy at
  `build-2/dlls/libarm64ecfex/aarch64-windows/` is what runs. This cost result 18
  a session and #12 an hour — assert on the loaded image, do not assume it.
- The toolchain must be on `PATH` for any build or for `tools/lint.sh`:
  `tools/toolchains/llvm-mingw-*/bin`. A missing archiver shows up as a bare
  `code=127`, and a missing `clang-format` fails lint with no diff.
- `spikes/*/work/` is gitignored local state. It can silently change what a test
  measures — the GFX-001 DXMT install still symlinks the pre-rename
  `Developer/macgaming` path (#35), which degrades a provider test into a
  builtin-provider test without saying so.

## Provenance

`third_party/src/fex` carries a no-AI policy with a founder-authorized exception
for `alloy/*` fork branches. AI-assisted commits there must be listed in
`third_party/src/fex/PROVENANCE-ALLOY.md`, and the authorization recorded in
`PROVENANCE.log` at the repo root. ADR-0012 excluded sources — vkd3d,
vkd3d-proton, DXMT `src/d3d12/` — are never read and never enter an AI context.
