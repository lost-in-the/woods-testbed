# Plan: a large-app variant that can actually measure the unmeasured claims

Addresses [woods-testbed#2](https://github.com/lost-in-the/woods-testbed/issues/2).

Status: **proposed** — investigation complete, nothing implemented yet.

---

## TL;DR

Four findings changed the shape of the answer:

1. **The candidate source is a dead end.** `JetBrains/sample_rails_app` *is* the
   Rails Tutorial sample app — the same codebase `apps/rails-8.0` and
   `apps/rails-7.2` are already forks of. Vendoring it adds roughly zero units.
   Go synthetic, which #2 already names as the legitimate alternative.
2. **Type coverage is a bigger hole than size.** The gem produces **34 unit
   types**; the existing variants exercise **13**. Twenty types have never run
   against a booted app anywhere except the gem's own `spec/dummy`. Fan-out
   measurement and type coverage want the same new variant, so build one thing.
3. **Docker works inside a Claude Code web session** — verified empirically in
   this one, see [Appendix A](#appendix-a-container-feasibility-measured-not-assumed).
   It needs a documented bootstrap (`dockerd` is not running at session start),
   not a different architecture.
4. **The embedding path has no testbed coverage at all**, and `rake woods:embed`
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

| Covered (13) | Zero coverage (20) |
|---|---|
| `models`, `controllers`, `jobs`, `mailers`, `routes`, `middleware`, `i18n`, `configurations`, `view_templates`, `migrations`, `action_cable_channels`, `test_mappings`, `rails_source` | `graphql`, `components` (Phlex), `view_components`, `services`, `serializers`, `managers`, `policies`, `validators`, `concerns`, `pundit_policies`, `engines`, `scheduled_jobs`, `rake_tasks`, `state_machines`, `events`, `decorators`, `database_views`, `caching`, `factories`, `libs`, `poros` |

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

### 1.5 Two small documentation drifts found in passing

- This README's Layout section lists a `share/` directory that does not exist.
- The gem's CLAUDE.md says a manual rake run "wait[s] 30s then proceed[s] with a
  warning". `lib/tasks/woods.rake` now says that reasoning was wrong — the wait
  is generous and the failure explicit, via `WOODS_LOCK_WAIT`. Worth a one-line
  fix in the gem repo.

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

**0a. Container bootstrap script.** `scripts/bootstrap_docker.sh` — starts
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
   is not. This is what `scripts/bootstrap_docker.sh` exists to fix.
2. **`HTTPS_PROXY` is set**, so `curl` to a container on `127.0.0.1` needs
   `--noproxy '*'` or it goes to the proxy and fails confusingly.

Conclusion: the testbed does **not** need a fundamentally different container
architecture for agents to build and test embedding features on the web. It needs
a bootstrap script, a compose profile, and two lines of documentation.
