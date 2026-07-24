<!-- Author: Tim Isaev -->

# Task workflow

Work is tracked as GitHub issues on the [Alloy board](https://github.com/users/cleverClosure/projects/1).
The system is designed for up to **two agents working in parallel** on this repo.

## Board columns

| Status | Meaning |
| --- | --- |
| **Backlog** | Not yet shaped: missing area/priority labels or unmapped dependencies. Never pickable. |
| **Todo** | Shaped and ready. Pickable once its blockers are closed and its areas are free. |
| **In Progress** | Claimed by an agent. Holds its area locks. |
| **On Hold** | Paused mid-work. **Still holds its area locks** — an unmerged branch means the files are still dirty. Keep the assignee. |
| **Done** | Merged and closed. |

## Shaping a task

Use the **Task** issue template. Every task must have, before it leaves Backlog:

- One `area:*` label per track it touches (`area:cpu`, `area:gfx`, `area:wine`,
  `area:store`, `area:rollback`, `area:m12`, `area:docs`, `area:tools`,
  `area:ci`, `area:third-party`). The labels must match the **Touches** paths.
- One `priority:P0` / `priority:P1` / `priority:P2` label.
- Native **blocked by** relationships (issue sidebar → Relationships) for every
  dependency. The text in "Depends on" is for humans; tooling reads only the
  native relationship.

Shaping rules that keep two agents busy:

- Slice by **area first, feature second** — the natural state is two disjoint
  streams that never contend.
- Keep dependency chains **≤ 2 deep**. Long chains serialize everything and the
  second agent starves.
- A task may carry two area labels only if it genuinely spans both; it then
  locks both.

## Picking a task (agent protocol)

Run the deterministic picker:

```bash
scripts/next-task.sh              # see what is eligible and why others are not
scripts/next-task.sh --claim bob  # claim the top task as agent "bob"
```

A task is eligible iff **all** of:

1. Board status is **Todo**.
2. It has **no assignee** — the assignee field is the lock; claiming = assigning.
3. Every native **blocked by** issue is closed.
4. Its `area:*` labels are disjoint from every task **In Progress or On Hold**.

`--claim` assigns you, moves the card to In Progress, and comments the agent
name. WIP limit: **one task per agent**.

## Finishing

- Branch per task: `task/<issue>-<slug>`.
- The PR description says `Fixes #<issue>` — merging closes the issue and the
  card lands in Done automatically.
- Abandoning a task cleanly (no branch kept): unassign yourself and move it
  back to Todo. Pausing with a branch: move to On Hold, stay assigned.
