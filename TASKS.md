<!-- Author: Timur Isaev -->

# Task workflow

Work is tracked as GitHub issues on the [Alloy board](https://github.com/users/cleverClosure/projects/1).
The system is designed for up to **two agents working in parallel** on this repo.
Both agents share one GitHub account; the board's **Agent** field (`claude` |
`codex`) records who holds a claimed task. Group the board by Agent for
per-agent swimlanes.

## Board columns

| Status | Meaning |
| --- | --- |
| **Backlog** | Not yet shaped: missing area/priority labels or unmapped dependencies. Never pickable. |
| **Todo** | Shaped and ready. Pickable once its blockers are closed and its areas are free. |
| **In Progress** | Claimed by an agent. Holds its area locks. |
| **On Hold** | Paused mid-work. **Still holds its area locks** — an unmerged branch means the files are still dirty. Keep the assignee. |
| **Done** | Merged and closed. |

## Shaping a task

Use the **Task** issue form. It refuses an issue with an empty PM summary,
Goal, Touches, Done when, Area or Priority, and turns the Area and Priority
choices into the matching labels. Every task must have, before it leaves Backlog:

- A title in `[<domain>-<issue#>]: <summary>` form; the Title format workflow
  normalizes legacy `DOMAIN: summary` titles and uses the first `area:*` label
  when no legacy prefix exists.
- A **PM summary**: plain language, no jargon — what it's about, why it
  matters, what's different when it's done. If the PM can't tell why the task
  exists from this paragraph alone, it isn't shaped yet.
- One `area:*` label per track it touches (`area:cpu`, `area:gfx`, `area:wine`,
  `area:store`, `area:rollback`, `area:m12`, `area:docs`, `area:tools`,
  `area:ci`, `area:third-party`). The labels must match the **Touches** paths.
- One `priority:P0` / `priority:P1` / `priority:P2` label.
- Native **blocked by** relationships (issue sidebar → Relationships) for every
  dependency. The text in "Depends on" is for humans; tooling reads only the
  native relationship.

### A blocker is not an area lock

`blocked by` means **this task needs something that task produces** — an
artifact, a decision, a merged mechanism. Nothing else.

Never use it to record that an area is busy. The picker already computes area
contention live from what is In Progress or On Hold, and that contention
disappears the moment the other task finishes. A `blocked by` edge does not:
it persists until a human deletes it. Writing a transient scheduling conflict
into the dependency graph freezes it there.

So: **every manually added blocker names the artifact it waits for, in the
issue's "Depends on" section.** If you cannot name the artifact, it is not a
dependency — leave it out and let the area lock do its job.

### Before deleting a blocker, read the body

The rule above has a mirror image, and it has already cost more than the
mistake it guards against.

On 25 July #23 was linked as blocked by #57. A review the next day saw two
issues sharing `area:ci`, searched the timeline for a comment explaining the
edge, found none, and deleted it as an area lock mistakenly recorded as a
dependency. The explanation was in #23's **Depends on** section the whole
time — "finish the current auto-merge gate work before changing the shared
packaging and CI surface" — which is exactly where this file says that
rationale belongs. The edge was also right on the merits: #57's PR modifies
`.github/workflows/ci.yml` and #23 adds a CI job to the same file.

Deleting a correct edge is worse than adding a wrong one, because the wrong
edge merely delays a task while the missing edge lets two agents collide in a
shared file. So before removing any `blocked by`:

1. read the blocked issue's **Depends on** section — the rationale lives
   there, not necessarily in a comment;
2. compare what the blocking task actually touches against what the blocked
   task will touch;
3. if it still looks wrong, comment and leave it for a human rather than
   deleting it. An edge is cheap to keep and expensive to be wrong about.

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
scripts/next-task.sh                 # see what is eligible and why others are not
scripts/next-task.sh --claim claude  # claim the top task as claude (or: codex)
```

A task is eligible iff **all** of:

1. Board status is **Todo**.
2. It is **not labeled `founder`** — founder-only work (FEX tree no-AI policy,
   license acceptances, purchases, legal, sign-offs) is never agent-claimable.
3. It has **no assignee** — the assignee field is the lock; claiming = assigning.
4. Every native **blocked by** issue is closed.
5. Its `area:*` labels are disjoint from every task **In Progress or On Hold**.

`--claim` assigns the account, sets the **Agent** field, moves the card to
In Progress, and comments the agent name. WIP limit: **four In Progress tasks
shared across all agents** — the script refuses a claim when all four slots
are occupied.

Effort is tracked in hours with two separate numeric fields:

- **Estimate** — set during shaping, before the task leaves Backlog.
- **Actual** — set when the task is finished, before it moves to Done. Preserve
  the original Estimate so estimated and actual effort remain comparable.

The optional **Iteration** field assigns a task to a weekly cycle starting on
Monday. Column headers can sum Estimate and Actual.

## Finishing

- Branch per task: `task/<issue>-<slug>`.
- The PR description says `Fixes #<issue>` — merging closes the issue and the
  card lands in Done automatically.
- Abandoning a task cleanly (no branch kept): unassign yourself and move it
  back to Todo. Pausing with a branch: move to On Hold, stay assigned.

### Merging is automatic

`.github/workflows/auto-merge.yml` squash-merges **every** non-draft PR into
`main` as soon as CI is green. There is no label or approval gate: **opening a
ready PR is the decision to merge it.**

- **A PR that needs a human call must be opened as a draft**, or converted back
  to one (`gh pr ready --undo <n>`). Drafts are skipped, and are re-evaluated
  when marked ready. This is the only brake — use it whenever the PR body asks
  the founder to decide something.
- Merges are squashes, so one commit lands on `main` per PR. A single-commit PR
  keeps its original message verbatim; a multi-commit PR gets all of its
  messages concatenated under the PR title. Shape the branch accordingly.
- A PR that closes a task is held until the card of every issue it closes has
  both **Estimate** and **Actual**. `scripts/finish-task.sh <issue> <hours>`
  records Actual and re-runs CI so the PR is looked at again; Estimate is set
  on the board. The hold is explained in one comment on the PR. A PR with no
  closing reference is not a task and is not gated.
- Nothing merges on a red or still-running check: the workflow requires
  GitHub's `CLEAN` merge state, which means mergeable *and* every check passed.
  Conflicts (`DIRTY`) and failing checks (`UNSTABLE`) are left alone.
- This is a workflow rather than GitHub's native auto-merge because native
  auto-merge needs branch protection with required checks, and protected
  branches need GitHub Pro on a private repo. If the repo ever moves to Pro,
  replace this with branch protection plus `gh pr merge --auto`.
