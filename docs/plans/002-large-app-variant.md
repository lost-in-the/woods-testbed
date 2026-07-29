# Plan: a large-app variant that can actually measure the unmeasured claims

Addresses [woods-testbed#2](https://github.com/lost-in-the/woods-testbed/issues/2).

Status: **in progress** — rungs 1–9 done (kernel 34/34; generator calibrated), see [`002-loop.md`](002-loop.md).

---

## TL;DR

Five findings changed the shape of the answer:

1. **The candidate source is a dead end.** `JetBrains/sample_rails_app` *is* the
   Rails Tutorial sample app — the same codebase `apps/rails-8.0` and
   `apps/rails-7.2` are already forks of. Vendoring it adds roughly zero units.
   Go synthetic, which #2 already names as the legitimate alternative.
2. **Type coverage is a bigger hole than size.** The gem produces **34 unit
   types**; the existing variants exercise **14**. Twenty types have never run
   against a booted app anywhere except the gem's own `spec/dummy`. Fan-out
   measurement and type coverage want the same new variant, so build one thing.
3. **Docker works inside a Claude Code web session** — verified empirically in
   this one, see [Appendix A](#appendix-a-container-feasibility-measured-not-assumed).
   It needs a documented bootstrap (`dockerd` is not running at session start),
   not a different architecture.
4. **But the testbed could not actually be *built* in one** until rung 2 fixed
   it (§1.5): container builds don't trust the egress CA, and the proxy is
   loopback-only so containers can't reach it. Both present as "the network is
   broken". This is the single most important finding for the question "can an
   agent on the web build and test features fully?"
5. **The embedding path has no testbed coverage at all**, and `rake woods:embed`
   cannot be driven without a live OpenAI or Ollama endpoint. That is a gem-side
   gap (`Builder`), not just a testbed gap.

The plan is one new variant (`apps/rails-8.0-large`), one committed generator,
one committed benchmark harness, a container profile for the storage/embedding
backends, and the CI this repo currently does not have.

---

## Part 1 — What the investigation found

### 1.1 `JetBrains/sample_rails_app` — rejected on size, not licence

| Check | Result |
|---|---|
| Licence | MIT + Beerware — vendoring or scripted import is fine |
| Rails version | 6th-edition tutorial app; 7.0.4 and 8.0.0 branches exist |
| Actual size | ~the same as `apps/rails-8.0` — it is the *same app* |
| Exercises fan-out paths | No: no services, no GraphQL, no concerns, no view components |

`apps/rails-8.0` and `apps/rails-7.2` are already described in this repo's
README as "minimal forks of the Rails Tutorial sample app". Adopting JetBrains'
copy would give us a third fork of a tree we already have twice.

**Decision: generate synthetically.**

### 1.2 Twenty of thirty-four unit types have zero booted-app coverage

`IndexReader::TYPE_DIRS` lists 34 type directories. Against `apps/rails-8.0`:

| Covered (14) | Zero coverage (20) |
|---|---|
| `models`, `controllers`, `jobs`, `mailers`, `routes`, `middleware`, `i18n`, `configurations`, `engines`, `view_templates`, `migrations`, `action_cable_channels`, `test_mappings`, `rails_source` | `graphql`, `components` (Phlex), `view_components`, `services`, `serializers`, `managers`, `policies`, `validators`, `concerns`, `pundit_policies`, `scheduled_jobs`, `rake_tasks`, `state_machines`, `events`, `decorators`, `database_views`, `caching`, `factories`, `libs`, `poros` |

> **Corrected at rung 2, from measurement.** This table first listed `engines`
> as uncovered. The rung-2 scaffold extracts **2 engine units with no in-repo
> engine at all** — `EngineExtractor` finds the engines Rails itself mounts. So
> `engines` needs nothing from the kernel, and the covered count is 14, not 13.
> The "twenty uncovered" headline is unchanged.

Concretely, the variant has no `app/models/concerns/`, no
`app/controllers/concerns/`, no `lib/`, no `app/services/`, no cache calls
anywhere in `app/`, and `jobs` is one `ApplicationJob` with no subclass.

This matters beyond tidiness. The gem's headline differentiator — **concern
inlining** — has no host app validating it. So does `CallbackAnalyzer`,
`RouteHelperResolver` navigation edges at scale, and the whole
`WHOLE_APP_EXTRACTORS` wholesale-replacement path that #2's finding 16 is about.

Good news for cost: most of these need **no gem**. Discovery is directory- or
regex-based:

| Type | What it actually needs |
|---|---|
| `factories` | files under `spec/factories` — DSL parsed statically |
| `scheduled_jobs` | a `config/recurring.yml`, `config/sidekiq_cron.yml`, or `config/schedule.rb` |
| `database_views` | `.sql` files under `db/views/` — Scenic not required to extract |
| `state_machines` | regex over `app/models` for `aasm do` / `state_machine :x do` — but the file must still **boot**, so `aasm` (tiny) is the honest way |
| `decorators`, `policies`, `managers`, `validators`, `serializers`, `pundit_policies`, `concerns`, `poros`, `libs`, `caching`, `rake_tasks` | plain Ruby in the right directory |
| `view_components`, `components` | gems (`view_component`, `phlex`) |
| `graphql` | see below — deliberately a two-state axis |

`GraphQLExtractor` is gated on `graphql_source_present?`, **not** on the gem
being loaded. So "graphql gem installed" vs "not installed" is a real matrix
dimension, and it is exactly the open B-066 / woods#167 question about the
runtime pass emitting units no file pass reproduces. The large variant should
be able to run both ways.

### 1.3 The embedding and storage backends are untested end to end

- The testbed runs **SQLite only**. No PostgreSQL, no MySQL, no pgvector, no
  Qdrant, no Ollama service anywhere in `docker-compose.yml`.
- `Builder#build_embedding_provider` knows exactly two providers, `:openai` and
  `:ollama`. `rake woods:embed` goes through it, so there is **no way to run the
  embedding pipeline from a host app without a live remote endpoint**.
- A deterministic `Woods::Embedding::Provider::Fake` already exists — bag-of-words
  hashing, L2-normalised, so cosine similarity stays meaningful — but it lives in
  the gem's `spec/support/`, unreachable from a host app.
- `rake woods:retrieve` hardcodes `Provider::Ollama` + `VectorStore::InMemory`,
  which contradicts the backend-agnostic rule in the gem's own CLAUDE.md.

A smoke script *can* sidestep the rake task today by constructing
`Woods::Embedding::Indexer.new(provider: <anything>)` directly — the Indexer
takes the provider as a kwarg. That is the zero-gem-change path, and it is what
Phase 5 uses first.

### 1.4 This repo has no CI

There is no `.github/` directory. Nothing catches variant bit-rot, and #2's
requirement that "a number from six months ago is comparable to one from today"
has no enforcement point. Benchmark numbers that only ever run by hand drift
into folklore.

### 1.5 The testbed could not be built in a web session at all (fixed at rung 2)

Discovered by rung 2 failing, and more consequential than anything else here for
"can an agent on the web build and test this?" — the answer was **no**, for two
reasons that both present as "the network is broken":

1. **Build containers don't trust the egress CA.** `gem install bundler` fails
   with `self-signed certificate in certificate chain` naming the session's
   egress gateway CA. Nothing in the image trusts it.
2. **The proxy listens on 127.0.0.1 only.** A container on the default bridge
   gets `connection refused` reaching `172.17.0.1`, so even with the CA trusted,
   `bundle install` cannot fetch. Verified directly: a busybox `wget` from a
   container to the host gateway is refused.

Neither is discoverable from the error messages, and both look like the
environment simply can't run Docker.

Fixed by `bin/ccr_compose.sh` + `docker-compose.ccr.yml`: build with
`--network host`, install the CA in an early image layer, and run with
`network_mode: host` so the container shares the namespace where the proxy is
reachable. On a laptop the wrapper detects no proxy and passes straight through
to `docker compose`, so the normal path is untouched.

Two consequences worth stating plainly:

- **`bundle install` has to happen at container start, not build time**, because
  the Gemfile carries `gem "woods", path: "/woods-gem"` and that path only
  exists as a runtime volume mount. So the *running* container needs proxy
  access, not just the build.
- **`network_mode: host` discards `ports:`**, so variants can't run side by side
  *under the overlay*.

### The overlay is only needed twice, not always

That second consequence looked like it would block rung 13 (six daemons at
once). It doesn't. **The overlay is needed for image builds and for the first
boot only** — the boot that populates the named bundle volume. Once that volume
is warm, `bundle install` resolves entirely from it and needs no network, so the
variant runs on ordinary bridge networking with `ports:` intact.

Verified: after one overlay boot, plain `docker compose up -d rails-8.0-large`
gives `NetworkMode: woods-testbed_default`, port 3013 mapped, and
`woods:extract` + `woods:validate` both green. So the working pattern behind a
proxy is:

```bash
bin/ccr_compose.sh build rails-8.0-large     # overlay: CA + host network
bin/ccr_compose.sh up -d rails-8.0-large     # overlay: warms the bundle volume
docker compose up -d rails-8.0-large         # thereafter: bridge + ports
```

Two further notes for rung 13:

- A durable version of this would vendor a gem snapshot into the image and run
  `bundle install --local` at runtime, moving the network need to build time
  permanently. Not required now, so not done.
- Rung 13 may not need multiple containers at all. `Rails.root` is a **process**
  singleton, not a container one — six daemon processes against six app copies
  inside one container satisfies the same constraint with far less machinery.

**Follow-up (not done here, per the append-don't-absorb rule):** only
`apps/rails-8.0-large/Dockerfile` has the CA layer. The other three variants
still can't build in a web session. The wrapper is already generic — retrofit
is one Dockerfile edit plus an empty `ca-bundle.crt` placeholder each.

### 1.6 Two small documentation drifts found in passing

- This README's Layout section lists a `share/` directory that does not exist.
- The gem's CLAUDE.md says a manual rake run "wait[s] 30s then proceed[s] with a
  warning". `lib/tasks/woods.rake` now says that reasoning was wrong — the wait
  is generous and the failure explicit, via `WOODS_LOCK_WAIT`. Worth a one-line
  fix in the gem repo.

### 1.7 A gem bug found by building the kernel (rung 4)

`StateMachineExtractor#detect_class_name` returns the **innermost** class name,
so `module Billing; class Payment` produces the unit identifier
`Payment::aasm` rather than `Billing::Payment::aasm`.

Consequences: every namespaced model with a state machine is misnamed in the
index, and two same-named classes in different namespaces (`Billing::Payment`
and `Legacy::Payment`) would collide on a single identifier — which is the
already-known B-062 collapse, reached by a second route.

Found because the kernel deliberately puts its state machine on a **namespaced**
STI base. A flat fixture would never have surfaced it, which is the argument for
the kernel's structural variety in miniature.

Recorded in `kernel_contract.yml` under `known_gem_issues` so the conformance
gate reports it without counting it as a kernel failure, and without the
contract encoding wrong behaviour as expected. Delete the entry when the gem is
fixed. **Not yet filed against `lost-in-the/woods`.**

### 1.8 One thing that looked like a gem bug and was not

STI subclasses (`Billing::CardPayment`, `Billing::BankPayment`) were discovered
by `discoverable_classes` but silently dropped by `extract_all` — the exact
shape of a full-vs-incremental divergence, and initially recorded as one.

It was not. `table_exists?` was false because the variant's development database
still held the *scaffold's* tables: the kernel's migrations reused the
scaffold's version numbers (`20240101000001`), so `schema_migrations` reported
them as already applied and `db:prepare` did nothing. Renumbering past the old
versions and rebuilding fixed it, and the STI assertions went green.

Worth recording for two reasons: reusing a migration version is a silent
footgun that presents as an extraction bug, and the diagnosis was slowed by
having redirected `db:prepare` output to `/dev/null`.

---

## Measured baseline (rung 2)

`apps/rails-8.0-large` scaffold, before any kernel content. Recorded so the
kernel's and generator's effect is measurable against a known floor.

| | |
|---|---|
| Rails / Ruby | 8.0.5 / 3.3.1 |
| Total units | **149** |
| of which `rails_source` | 120 (81%) — i.e. only **29 units** are app code |
| Non-zero types | 10 of 34 |

Per type: `models` 2, `controllers` 1, `jobs` 1, `routes` 10, `middleware` 1,
`i18n` 1, `configurations` 4, `engines` 2, `view_templates` 5, `migrations` 2,
`rails_source` 120. Everything else zero.

That `rails_source` is 81% of the index at this size is itself worth noting for
the benchmark design: the whole-app re-run percentage in finding 16 is a
fraction of the *whole* index, so a variant whose index is mostly framework
source would understate it. The generator has to move app-code units by enough
that `rails_source` becomes a rounding error.

---

## Kernel complete (rungs 4–7)

`apps/rails-8.0-large` after the kernel, before any generated tree:

| | |
|---|---|
| Total units | 290 |
| App-code units | 91 (was 29 at scaffold) |
| `rails_source` | 199 — **68%**, down from 81% |
| Types non-empty | **34 / 34** |
| Contract assertions | 52, all passing |
| Known gem issues | 5, partitioned off the gate |
| `woods:validate` | clean |

Every one of the 20 types that had never run against a booted app now does.

**A note for the benchmark rung.** `woods:validate` initially reported five
count mismatches (`models: expected 10, found 12`). Those were stale unit files
from the scaffold era: **a full extraction overwrites unit files but does not
prune orphans**, so an output directory that has seen an earlier, different app
over-reports. `woods:clean` first, then extract, or every unit count the
benchmark reports is inflated by whatever the directory used to contain.

### The five known gem issues

All found by building the kernel, all recorded in `kernel_contract.yml` with
rationale, and all now filed against `lost-in-the/woods`:

1. **`StateMachineExtractor#detect_class_name`** returns the innermost class
   name — `Billing::Payment`'s machine is indexed as `Payment::aasm`. → [woods#174](https://github.com/lost-in-the/woods/issues/174)
2. **`ServiceExtractor`** does the same — `app/use_cases/billing/issue_invoice.rb`
   becomes `IssueInvoice`, not `Billing::IssueInvoice`. Same root cause, same
   cross-namespace collision risk. → [woods#174](https://github.com/lost-in-the/woods/issues/174)
3. **`ControllerExtractor#extract_included_concerns`** selects included modules
   by whether the module *name contains the string* `"Concern"`. An
   idiomatically named controller concern is never recorded, though its
   `before_action` **is** picked up in `filters`. → [woods#175](https://github.com/lost-in-the/woods/issues/175)
4. **Controller concern source is not inlined** the way model concern source is.
   Possibly by design; the gem's CLAUDE.md only ever claims it for models.
   → [woods#175](https://github.com/lost-in-the/woods/issues/175) (second half)
5. **`RakeTaskExtractor#parse_task_signature`** requires a leading colon on the
   task name, so the modern `task archive_stale: :environment` form — what most
   Rails apps write — yields no unit at all.

Three of the five (1, 2, 5) would be invisible to a flat, conventionally-named
fixture. That is the argument for the kernel's structural variety, stated as
evidence rather than as a hope.

### Filed against the gem

Every gem-side finding in this document now has an issue:

| Issue | Finding | Where found |
|---|---|---|
| [woods#174](https://github.com/lost-in-the/woods/issues/174) | Namespace lost in class-name detection (`StateMachineExtractor`, `ServiceExtractor`) | rungs 4–5 |
| [woods#175](https://github.com/lost-in-the/woods/issues/175) | Controller concerns never recorded — name-string matching; plus the inlining asymmetry | rung 5 |
| [woods#176](https://github.com/lost-in-the/woods/issues/176) | `RakeTaskExtractor` misses `task name: :environment` | rung 6 |
| [woods#177](https://github.com/lost-in-the/woods/issues/177) | Full extraction leaves orphaned unit files; counts over-report | rung 7 |
| [woods#178](https://github.com/lost-in-the/woods/issues/178) | Embedding pipeline undrivable without a live provider; `woods:retrieve` hardcodes backends | §1.3 |
| [woods#179](https://github.com/lost-in-the/woods/issues/179) | CLAUDE.md describes the superseded lock-wait behaviour | §1.6 |

`kernel_contract.yml`'s `known_gem_issues` entries carry the issue numbers, so
deleting an entry when its issue closes is the whole cleanup.

### Extractor conventions worth knowing

Not bugs — definitions that are simply narrower than their names suggest, each
now pinned by a fixture:

- **`manager`** means a *delegator*: `< SimpleDelegator`, `< DelegateClass(…)`,
  or `include Delegator`. A service-shaped class in `app/managers` yields nothing.
- **`serializer`** is recognised by shape, not directory — needs
  `< ApplicationSerializer` / `< ActiveModel::Serializer` / an `attributes :`
  DSL. A plain PORO in `app/serializers` yields nothing.
- **`pundit_policy`** requires Pundit's `user`/`record` naming. Name the
  constructor args `author`/`article` and the policy is invisible to that
  extractor (it still registers as a plain `policy`).
- **`policy` and `pundit_policy` both scan `app/policies`** and one class can be
  both, so the conformance script tracks a *set* of type directories per
  identifier rather than one.

---

## Scale calibration (rung 9, measured)

Two data points, because one cannot establish a slope. The kernel contributes a
fixed 91 app-code units, so the figure that matters is the **marginal** rate per
generated family, not units divided by scale.

| Scale | Families | Total units | App-code units | Marginal units/family |
|---|---|---|---|---|
| `small` | 20 | 464 | 265 | 8.70 |
| `medium` | 200 | 1,940 | 1,741 | 8.25 |

Projection at the committed `large` preset:

| Families | App-code units | Total units |
|---|---|---|
| 500 | ~4,216 | ~4,415 |
| 700 | ~5,866 | ~6,065 |
| **875** | **~7,309** | **~7,508** |

`large = 875` therefore lands inside the 6,000–8,000 band and within ~3% of the
~7,100-unit host behind #2's finding 16 — so the whole-app re-run percentage
measured here is directly comparable. **No recalibration needed**; the preset
stands as committed.

Two side effects worth recording:

- **The `rails_source` dilution problem solves itself with scale.** It was 81% of
  the index at the scaffold and 68% after the kernel; at `medium` it is 10%, and
  at `large` it projects to ~2.6%. The whole-app re-run percentage stops being
  distorted by framework source without needing `include_framework_sources =
  false`.
- **Cold full extraction at `medium` (1,940 units) takes 7.8s** in-container.
  That is the first real data point for rung 10's harness and suggests `large`
  will be well under a minute.

The contract gate stays green with the generated tree present at both scales —
so the `Gen` prefix is doing its job and no generated identifier collides with a
kernel one.

### A dependency removed rather than added

`scenic` was added in rung 4 "for realism" and had to come out: it hooks the
schema dump with PostgreSQL-only queries (`pg_class`, `pg_get_viewdef`) and takes
`db:prepare` down on SQLite with `no such table: pg_class`. `DatabaseViewExtractor`
reads `db/views/*.sql` statically and never needs the gem, so `database_view`
units are produced either way. The dependency bought nothing and cost a boot —
and it is a concrete instance of the backend-agnostic problem the testbed exists
to surface.

---

## Part 2 — The plan

### Shape of the deliverable

One new variant, built in two layers:

```
apps/rails-8.0-large/
├── app/…, lib/…, db/…, config/…   ← the KERNEL: one idiomatic instance
│                                     of every one of the 34 unit types,
│                                     hand-written, ~60 files, committed
└── app/generated/, db/generated/  ← MULTIPLIED output, gitignored
scripts/
├── generate_large_app.rb          ← deterministic, scale-parameterised
├── woods_bench.rb                 ← the benchmark harness
├── bench_changes/                 ← fixed, committed change scripts
└── woods_type_coverage_smoke.rb   ← asserts all 34 types are non-empty
```

**Why kernel + generator rather than a vendored tree.** A committed 5,000-file
Rails app is unreviewable and makes every future diff useless. A generator keeps
the git footprint small and the scale tunable. The reproducibility that a
committed tree would buy is recovered by recording, in every benchmark result,
the generator version, the scale parameter, and a checksum of the generated
tree — so a number from six months ago is self-describing.

**Why the kernel is hand-written.** Generated code is the wrong fixture for
"does concern inlining work" — you want to read the concern and read the
inlined output. The kernel doubles as the type-coverage fixture and as the
readable half of the variant.

**Scale target.** #2's reviewer measured 1,707 units at 24% of their index,
implying ~7,100 units. Default `WOODS_GEN_SCALE` should land the variant at
**~6,000–8,000 units** so the whole-app re-run percentage is directly
comparable. Scale is a knob; CI uses a smaller value.

---

### Phase 0 — Foundations (unblocks everything else)

**0a. Container bootstrap script.** `bin/bootstrap_docker.sh` — starts
`dockerd`, waits for the socket, prints readiness. Documented in the README with
the web-session caveat from Appendix A. Without this, an agent on the web/app
concludes Docker is unavailable and stops. This is the single highest-leverage
item in the plan and costs almost nothing.

**0b. CI.** `.github/workflows/ci.yml`, modelled on the gem's `ci.yml`:
- build each variant, boot it, run `woods:extract` + `woods:validate`
- run every script in `scripts/` against `rails-8.0`
- run the benchmark at a small scale and **upload the JSON as an artifact**
  (gate on completion, not on thresholds — hardware varies between runners)

**0c. Fix the README's phantom `share/`** reference.

---

### Phase 1 — The kernel app

New `apps/rails-8.0-large/`, Rails 8.0, its own bundle volume, its own
container, port 3013. Hand-written, one instance of each uncovered type:

- **Structural variety #2 asks for**: namespaced models (`Billing::Invoice`),
  STI (`Payment` → `CardPayment`/`BankPayment`), a concern included by three
  models, a non-standard service directory (`app/use_cases/`), view templates
  using `_path` helpers so navigation edges resolve, and an `app/graphql/` tree.
- **Everything else in the zero-coverage column**: `app/decorators`,
  `app/policies`, `app/serializers`, `app/validators`, `lib/tasks/*.rake`,
  `db/views/*.sql` with two `_vNN` versions (so the "latest only" rule is
  observable), `config/recurring.yml`, `spec/factories/`, cache calls in a
  controller and a view, an `aasm` state machine, a publish/subscribe event
  pair, a mounted in-repo engine.
- **Gems added**: `view_component`, `phlex`, `aasm`, `scenic`, `pundit`,
  `factory_bot_rails`, `active_model_serializers`. All small.
- **GraphQL as a two-state axis**: `graphql` in an optional bundle group, driven
  by `WOODS_TESTBED_GRAPHQL=0|1`, so B-066 / woods#167 is reproducible.

**Deliverable check:** `scripts/woods_type_coverage_smoke.rb` reads `_index.json`
and fails if any of the 34 `TYPE_DIRS` is empty on this variant. Written to run
against *any* variant, so it also documents what the small variants deliberately
lack.

---

### Phase 2 — The generator

`scripts/generate_large_app.rb`, run inside the container before boot:

- **Deterministic**: seeded PRNG, no timestamps, no `rand` without a seed. Same
  scale in, byte-identical tree out.
- **Parameterised**: `WOODS_GEN_SCALE` (default targets ~7,000 units;
  `WOODS_GEN_SCALE=small` for CI).
- **Realistic association density**, not a flat pile: `belongs_to`/`has_many`
  webs, a handful of deliberate hubs (a `User`-shaped model many others point
  at) so PageRank has something to rank, and some cycles.
- **Multiplies every kernel shape**, not just models — generated services,
  jobs, controllers with route entries, view templates with `_path` references,
  concerns included across generated models.
- **Writes a manifest**: `tmp/generated_manifest.json` with the generator
  version, scale, file count, and a tree checksum. The benchmark embeds this.
- Generated paths are gitignored; the Dockerfile `CMD` regenerates when absent.

**Sizing is a calibration step, not a guess.** First run measures units-per-scale
on real hardware; the default is then pinned to hit the 6,000–8,000 band.

---

### Phase 3 — The benchmark harness

`scripts/woods_bench.rb`, following the gem's `bench/` documented-header
convention (what it measures / how to run / what "good" looks like).

Reports, as **JSON to stdout plus a human table**:

| Measurement | How |
|---|---|
| Unit count, by type | `_index.json` |
| Cold full extraction wall time | `Extractor#extract_all` on a cleared output dir |
| Incremental p50/p95 × 4 scenarios | N repetitions of each change script through `Extractor#extract_changed` |
| Whole-app re-run cost | units replaced, and as a **% of the index** — the number finding 16 needs |
| Phase breakdown | extract / dependents / PageRank / graph analysis / write, so "PageRank dominates" stops being a guess |
| RSS after N cycles | `VmRSS` from `/proc/self/status`, sampled per cycle |

The four scenarios are exactly #2's: **model change, controller change,
`config/routes.rb` change, `db/schema.rb` change** — the last two being the
fan-out cases.

Every result carries the generator manifest, Rails/Ruby versions, the gem SHA,
and the variant name, so a stored number stays interpretable.

---

### Phase 4 — Fixed change scripts

`scripts/bench_changes/` — one small committed Ruby script per scenario, each
with `apply` and `revert`. Ad-hoc edits are what make old numbers
incomparable; these are the fix. They should be *semantically* meaningful
(add a scope, add a route, add a column) rather than whitespace churn, so the
downstream fan-out is real.

---

### Phase 5 — Daemon-at-scale and bind-mount latency

- **Per-daemon memory at six-worktree scale.** Six containers, six
  `Rails.root`s, six daemons. `Rails.root` is a process singleton so this
  genuinely cannot be done in one Ruby process — containers are the natural
  answer and the testbed is the natural home. Report aggregate and per-daemon RSS.
- **Bind-mount event latency.** `scripts/bench_watch_latency.rb`: touch a file
  on the host side of the mount, measure time to the `generation.json` bump
  inside the container, with `listen` and with `WOODS_WATCH_POLL=1`. Note
  honestly that Linux CI bind mounts are **not** Docker Desktop's
  osxfs/gRPC-FUSE — the macOS number needs a macOS host, and the script should
  print which it ran on rather than let the two get conflated.

---

### Phase 6 — The container stack for storage and embedding

This is the user's second question, and the answer is: **yes, and it is cheap.**

Add an opt-in compose profile (so the default `docker compose up` stays fast):

| Service | Image | Purpose |
|---|---|---|
| `postgres` | `pgvector/pgvector:pg16` | Postgres primary DB *and* pgvector store |
| `mysql` | `mysql:8` | the backend-agnostic claim's other half — MySQL forces the external-vector-store path |
| `qdrant` | `qdrant/qdrant:v1.12.1` | external vector store |
| `ollama` | `ollama/ollama` | real embedding provider, model pulled on first run |

Plus a `DATABASE_ADAPTER` env switch on the large variant so the *same* app
boots on SQLite, Postgres, or MySQL — which is what actually tests
"never hardcode or default to a single backend".

**Two tiers of embedding test, deliberately:**

1. **Deterministic, no network, runs in CI.** A smoke script builds
   `Embedding::Indexer.new(provider: <deterministic fake>, vector_store: …)`
   directly and asserts round-trip through pgvector and through Qdrant. Works
   today with no gem change.
2. **Real provider, opt-in, not in CI.** Ollama with `nomic-embed-text` —
   validates the dimension contract, the 1.5-chars/token Ollama path, and
   `IndexValidator`'s dimension-mismatch detection.

**One gem-side change is worth proposing** (separate PR, woods repo): let
`Builder` accept an injected provider object or a `:fake` symbol, so
`rake woods:embed` is drivable in a host app without a live endpoint. Without
it, tier 1 can only ever be script-shaped, never rake-shaped, and the actual
`woods:embed` → `woods:retrieve` chain stays untested end to end. While there,
fix `woods:retrieve`'s hardcoded Ollama + InMemory.

---

### Phase 7 — Close the loop

The acceptance criterion is in the **gem** repo, not this one. A follow-up PR to
`lost-in-the/woods` replaces the three extrapolated claims in
`docs/WATCH_DAEMON.md` — the "Not yet measured, and the honest gap" paragraph
and the "Not covered" table row — with measured numbers, naming
`apps/rails-8.0-large` and `scripts/woods_bench.rb` as their source.

---

## Sequencing

| Order | Phase | Why here |
|---|---|---|
| 1 | 0a container bootstrap | Unblocks every agent on web/app. Minutes of work. |
| 2 | 1 kernel app | Standalone value: closes 20 type-coverage gaps whether or not the rest lands. |
| 3 | 0b CI | Locks in what Phase 1 built before it can rot. |
| 4 | 2 generator, 3 harness, 4 change scripts | The measurement machine. Ship together — none is useful alone. |
| 5 | 6 container profile | Independent of 2–4; can be parallelised. |
| 6 | 5 daemon-at-scale | Needs the large variant to exist. |
| 7 | 7 gem doc update | The acceptance criterion. |

Phases 1 and 6 each stand alone. If the effort has to be cut short, **Phase 0a +
Phase 1 is the highest value-per-hour slice** and leaves the repo strictly
better regardless of what happens to the benchmark work.

---

## Risks and open questions

| Risk | Mitigation |
|---|---|
| Generator drift makes old numbers incomparable | Generator version + scale + tree checksum embedded in every result |
| A 7,000-unit app makes CI slow | `WOODS_GEN_SCALE=small` in CI; full scale on demand / nightly |
| Benchmark thresholds fail on noisy shared runners | CI gates on *completion*, not on numbers; thresholds are for local runs |
| macOS bind-mount behaviour is the actual question and CI is Linux | Script prints its host type; the macOS figure is explicitly a local-run measurement |
| Identifier collisions (gem backlog B-062) at scale | Generator gives each family a name prefix, as the #164 harness does |
| Adding 7 gems to a variant slows its bundle | Own bundle volume; the small variants are untouched and stay fast |

**Open question for the maintainer:** should the large variant track Rails 8.0
only, or become a fourth row of the version matrix? Recommendation: **8.0 only**.
It exists to measure scale, not version behaviour, and multiplying it across
three Rails versions triples build time for a dimension the small variants
already cover.

---

## Appendix A — Container feasibility, measured not assumed

Run inside a Claude Code web session (this one), 2026-07-27:

| Check | Result |
|---|---|
| `docker` CLI | present, Engine 29.3.1 |
| `docker compose` | present, v5.1.1 |
| `/var/run/docker.sock` at session start | **absent — daemon not running** |
| Starting `dockerd` manually (as root) | **works**; overlayfs, cgroup v1 |
| `docker pull` through the agent proxy | works — `alpine`, `pgvector/pgvector:pg16`, `qdrant/qdrant:v1.12.1` |
| pgvector container | boots; `CREATE EXTENSION vector` → 0.8.5 |
| Qdrant container | boots; HTTP API answers on the mapped port |
| Free disk | ~30 GB |

Two gotchas worth writing into the README:

1. **`dockerd` must be started by hand.** The socket is absent at session start,
   so `docker ps` fails with a message that reads like Docker is unavailable. It
   is not. This is what `bin/bootstrap_docker.sh` exists to fix.
2. **`HTTPS_PROXY` is set**, so `curl` to a container on `127.0.0.1` needs
   `--noproxy '*'` or it goes to the proxy and fails confusingly.

Conclusion: the testbed does **not** need a fundamentally different container
architecture for agents to build and test embedding features on the web. It needs
a bootstrap script, a compose profile, and two lines of documentation.
