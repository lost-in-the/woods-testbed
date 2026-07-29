# Loop strategy for #2

How to implement [`002-large-app-variant.md`](002-large-app-variant.md) as a
resumable loop rather than one long session.

---

## The core idea: state is derived, not remembered

The failure mode of a long implementation loop is an iteration that doesn't know
where it is — so it redoes finished work, or trusts a note from three iterations
ago that was wrong.

So **the loop does not read a status file to decide what to do next. It runs the
verification ladder and does the first thing that fails.** Notes are breadcrumbs;
the gates are the truth. If a previous iteration recorded "kernel done" and the
type-coverage smoke says 19/34, the smoke wins and the loop resumes there.

That single property is what makes this a loop rather than a to-do list being
walked by an agent with amnesia.

---

## The slice ladder

Each rung is one iteration: small enough to finish, big enough to commit, and
gated by a command that returns an exit code rather than an opinion.

| # | Slice | Verification gate |
|---|---|---|
| 1 | Container bootstrap + README fixes (Phase 0a, 0c) | `bin/bootstrap_docker.sh && docker ps` exits 0 |
| 2 | `rails-8.0-large` scaffold — boots, extracts, validates | `woods:extract && woods:validate` green in-container |
| 3 | Naming contract for the kernel (see below) | `woods_contract_smoke.rb` runs and reports a precise, non-empty violation list (exit 2) |
| 4–7 | Kernel type families | `woods_contract_smoke.rb` exit 0 — violations strictly decrease each iteration (62 → 36 → 22 → 0) |
| 8 | CI workflow (Phase 0b) | Workflow run green on the branch |
| 9 | Generator (Phase 2) | Generate twice → identical tree checksum; scale calibration recorded |
| 10 | Benchmark harness (Phase 3) | Emits JSON containing every required key at `--scale small` |
| 11 | Change scripts (Phase 4) | Each `apply` dirties the tree; each `revert` leaves `git diff` empty |
| 12 | Container profile: pgvector + Qdrant + MySQL (Phase 6) | Deterministic-provider round-trip smoke passes against both stores |
| 13 | Daemon-at-scale + bind-mount latency (Phase 5) | Numbers produced, host type recorded |
| 14 | Gem-side `Builder` injected-provider PR | Gem suite green; `rake woods:embed` runs with no live endpoint |
| 15 | Gem doc update replacing the three extrapolated claims (Phase 7) | PR open against `lost-in-the/woods` |

Slices 12 and 14 are independent of 9–11 and can be pulled forward if something
upstream blocks.

---

## The progress metric

Phase 1 has an unusually good one: **covered types / 34**, printed by
`woods_type_coverage_smoke.rb`.

It is monotonic, it is a single integer, and it cannot be faked by an iteration
that felt productive. Every kernel iteration must move it. An iteration that
doesn't is a failed iteration, not a partial one — and it says so in the commit.

After the kernel, the metric becomes **rungs green / 15**.

---

## Loop invariants

Six rules. The first three prevent drift; the last three prevent damage.

1. **Never start rung N+1 while rung N is red.** The ladder is ordered because
   the gates depend on each other.
2. **Never end an iteration with an uncommitted tree.** Either the slice is done
   and committed, or it is reverted and the blocker is recorded. A half-finished
   working tree is invisible to the next iteration's gates.
3. **One commit per rung.** History should read as the plan, so a bisect lands on
   a slice boundary.
4. **Discovered work is appended, never absorbed.** New bug or gap → a line in
   the plan doc, not a widened slice. Same rule as the gem's backlog workflow,
   and it's what keeps a 15-rung ladder from becoming 15 sprawling ones.
5. **Calibration numbers get committed the moment they're measured** —
   units-per-scale, cold extraction time, the whole-app re-run percentage. These
   are the deliverable; losing one to a session boundary means re-running a
   multi-minute container job to learn it again.
6. **Circuit breaker: two consecutive failures of the same gate with the same
   error stops the loop and asks.** Grinding on an unchanged failure is the most
   expensive thing a loop can do.

---

## The contract-first rung

Rung 3 exists because of the coherence problem: the kernel's value is the
*edges* between files, and an iteration that adds five types in isolation
produces five islands.

So before any kernel content, one iteration writes
`apps/rails-8.0-large/KERNEL_CONTRACT.md` — the model names, namespaces, STI
hierarchy, which concern is included by which models, which route helpers the
view templates reference, which service calls which model. Every later kernel
iteration conforms to it instead of re-deciding.

This is cheap insurance in a single-context run and load-bearing across a
session boundary, where "what did I name the invoice model" is otherwise
unanswerable without reading the tree.

**Its gate is mechanical, not human.** The contract was first gated on the
maintainer's review, which put a person on the loop's critical path for a rung
that mostly encodes decisions rather than making contentious ones. Instead the
contract is machine-readable (`kernel_contract.yml`) and
`scripts/woods_contract_smoke.rb` enforces it against a real extraction. Review
becomes advisory; the loop only truly stops on the decisions listed under Stop
conditions.

Rung 3 passes when the check **fails usefully** — exit 2 with a precise,
non-empty list. That list is the worklist for rungs 4–7, and it is the same
red-test-first shape the gem's own CLAUDE.md mandates for new features. The
check asserts *edges*, not counts: concern inlining from the including model's
`metadata.inlined_concerns`, STI parentage from `metadata.parent_class`,
navigation edges from `dependency_graph.json`.

---

## Cadence

**Dynamic, not fixed-interval.** A 10-minute tick is wrong here in both
directions: container builds and bundle installs run for minutes, so a fixed
tick fires mid-install and finds nothing new; and a fast rung like the bootstrap
script shouldn't wait ten minutes to be followed by the next.

- **Working inline:** no wakeups at all. Finish rung, run gate, commit, continue.
- **Waiting on something the harness tracks** (a background build, a spawned
  task): no polling — the completion notification re-invokes. Schedule only a
  long fallback (~20–30 min) so a hung build can't silently end the loop.
- **Waiting on CI** (rung 8): a real external wait — one wakeup sized to the
  actual run length, not a poll every minute.

---

## Stop conditions

The loop ends on any of:

- **Done** — all 15 rungs green and the gem doc PR open. This is the success exit
  and the only one that needs no follow-up.
- **Blocked** — a gate fails twice identically (invariant 6).
- **Decision needed** — anything that changes the plan's shape rather than
  executing it. Two are already predictable: the scale calibration at rung 9
  landing far off the 6,000–8,000 band, and the open question about whether the
  large variant tracks Rails 8.0 only.
- **Budget** — if a token target is set, stop at the last rung that fits, with
  the tree committed and green. Never start a rung that can't be finished and
  committed.

---

## What this deliberately is not

Not a workflow fan-out. The rungs are sequential by dependency, the gates are
scripts rather than judgements, and the bottleneck is one Docker daemon and one
disk allowance — none of which parallelism improves. The loop's value here is
**resumability across session boundaries and long container waits**, not
concurrency.
