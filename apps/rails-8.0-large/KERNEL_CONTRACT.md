# Kernel contract

The naming and wiring scheme every hand-written file in this variant conforms
to. `kernel_contract.yml` is the machine-readable source of truth;
`scripts/woods_contract_smoke.rb` enforces it against a real extraction. This
file explains **why** it is shaped the way it is.

Rung 3 of [`docs/plans/002-loop.md`](../../docs/plans/002-loop.md).

---

## Why a contract at all

The kernel's value is not that 34 directories are non-empty. It is the **edges
between them** — a concern inlined into three models, a view template whose
route helper resolves to a controller, a use case that reaches a model that a
job enqueues.

Write the kernel in slices without a contract and you get 34 islands: a fixture
that passes every per-type coverage check while exercising none of the fan-out
paths the variant exists to measure. Worse, the failure is invisible — the
counts all look right.

So the naming is decided once, up front, and every later slice conforms to it
instead of re-deciding. Across a session boundary this is the difference between
resuming and re-reading the whole tree to recover "what did I call the invoice
model".

## The domain

A publishing platform with billing. Not arbitrary — it produces genuine
cross-cutting edges. An article is published by a use case, which enqueues a
job, which mails an author and issues an invoice against a payment. That is a
chain across six unit types, which is what makes it a fan-out fixture rather
than a directory listing.

```
Author ──< Article ──< Comment
  │           │
  │           └──< ArticleTag >── Tag
  │
  └──< Billing::Invoice ──< Billing::LineItem
              │
              └── Billing::Payment (STI) ── CardPayment / BankPayment
```

`Author` is the deliberate **hub**: several models point at it, so PageRank has
something to rank and the dependents pass has real fan-in to resolve rather than
a uniform graph where every node scores the same.

## The load-bearing decisions

**`Archivable` is included by exactly three models.** Concern inlining is the
gem's headline differentiator and has had no host-app coverage anywhere. One
includer would not exercise it meaningfully; three does. The smoke asserts the
count *exactly*, so an include that silently disappears fails the gate — where a
"is the concerns directory non-empty" check would still pass.

**`Auditable` intersects the STI base.** Inlining and STI interact; testing them
in separate files would miss that.

**Services live in `app/use_cases`.** One of `ServiceExtractor`'s five
directories, and the one a real host app is least likely to have. #2 asks for a
non-standard service directory specifically.

**Two policy files with different method shapes.** `PolicyExtractor` and
`PunditExtractor` *both* scan `app/policies` and discriminate on method names —
Pundit's `index?`/`show?`/`create?` versus decision-shaped `allowed?`/`eligible?`.
A kernel with one policy file leaves one of the two types permanently empty and
nothing would say so.

**A PORO under `app/models`.** `poro` is defined as a non-ActiveRecord class in
the models directory, so `WordCount` has to live there to be one.

**Two versions of the Scenic view.** `popular_articles_v01.sql` and `_v02.sql`,
because `DatabaseViewExtractor` keeps only the highest `_vNN` — and that rule is
why the type is dispatched wholesale rather than per file. Shipping one version
would not exercise it.

## What the kernel does *not* supply

`engine`, `middleware`, `rails_source`, `configuration`, `route`, `i18n`,
`migration`, `action_cable_channel`. These come from the framework or from files
the scaffold already has. Recorded in the contract's `supplied_by_framework`
list so nobody goes hunting for kernel files that were never meant to exist.

`engines` in particular: the scaffold extracts **2 engine units with no in-repo
engine at all**, because `EngineExtractor` finds the engines Rails itself
mounts.

## The generated tree

The generator (rung 9) multiplies the kernel. Everything it emits carries the
`Gen` prefix and lives under `app/generated` / `db/generated`, so a generated
unit can never collide with a kernel unit — the same trick the gem's #164
differential harness uses to sidestep the known identifier-collision issue
(B-062), where two units of different types sharing an identifier collapse onto
one graph node.

## Running the check

```bash
docker exec woods-testbed-rails-8.0-large bash -lc \
  'cd /app && bin/rails woods:extract && bin/rails runner script/shared/woods_contract_smoke.rb'
```

Exit `0` conformant, `1` no index, `2` violations listed. It **fails by design**
until the kernel is built — the precise list of what's missing is the output,
and it is the worklist for rungs 4–7.

Variants without a `kernel_contract.yml` skip cleanly, since `scripts/` is
mounted into all of them.
