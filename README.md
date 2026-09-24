# woods-testbed

Host Rails apps used to exercise the [woods](https://github.com/lost-in-the/woods)
gem against a real, booted Rails environment. The gem can't be fully
validated by unit tests alone: extraction and the Console MCP server
both require a live Rails boot with models, routes, and a database.

This repo carries **one Rails app per supported Rails version**, plus targeted
adapter and scale variants where a version-only matrix would miss behaviour.
They're minimal forks of the [Rails Tutorial sample app](https://github.com/mhartl/sample_app_6th_ed)
or deliberately small fixtures with the woods gem wired in and a handful of
woods-specific smoke scripts that assert behavioural invariants.

## Variants

| Variant | Rails | Ruby | Port | Container |
|---|---|---|---|---|
| `apps/rails-8.0` | 8.0.x | 3.3.1 | 3010 | `woods-testbed-rails-8.0` |
| `apps/rails-7.2` | ~> 7.2.0 | 3.3.1 | 3011 | `woods-testbed-rails-7.2` |
| `apps/rails-6.0` | ~> 6.0.0 | 3.0 | 3012 | `woods-testbed-rails-6.0` |
| `apps/rails-8.0-large` | 8.0.x | 3.3.1 | 3013 | `woods-testbed-rails-8.0-large` |
| `apps/rails-6.0-mysql` | ~> 6.0.0 | 3.0 | 3014 | `woods-testbed-rails-6.0-mysql` |

The 8.0 and 7.2 variants are minimal forks of the Rails Tutorial sample app.
The **rails-6.0** variant — the supported floor (`railties >= 6.0`, woods #135)
— is a deliberately minimal, backend-only app (`Post`/`Comment`, a controller, a
job, a mailer; no asset pipeline or JS bundler) so the Rails 6.0 boot stays small.
It's validated via Docker/CI rather than the host, since Ruby 3.0 / Rails 6.0
aren't installed on most dev machines.

The **rails-8.0-large** variant is [Canopy](apps/rails-8.0-large/README.md), a
working publishing testbed with editorial review, subscriptions, billing,
newsletters, and support across 29 domain tables. Deterministic smoke/demo/stress
datasets exercise Console queries; an optional source generator independently
scales extraction benchmarks. Its `Dockerfile` runs `db:prepare` at boot, as does
the MySQL contract variant. Open http://localhost:3013 and choose a demo editor.

The **rails-6.0-mysql** variant is the Rails 6.0 floor app wired to `mysql2`
instead of SQLite. It rides the `backends` Compose profile with the shared
`mysql` service and exists for adapter/dialect contracts, especially Console
SQL paths that must reach a real MySQL connection.

Each variant has its own `Gemfile`, its own bundle volume, and its own
container. They share `scripts/` (woods smoke scripts) via a read-only
bind mount at `/app/script/shared` inside the container.

Contributing a new Rails version: copy an existing `apps/rails-X.Y`
directory, edit the Gemfile pin, add a new service to
`docker-compose.yml`, and update the table above. CI checks that the variant
table stays in sync with Compose service names, containers, and default ports.

## Prerequisites

- Docker + Docker Compose (v2)
- A local checkout of the [woods gem](https://github.com/lost-in-the/woods)

### Running in a Claude Code web/app session

The variants work in a remote Claude Code session, but two things differ from a
laptop and both look like hard failures if you don't know them.

**1. The Docker daemon isn't running.** The `docker` CLI and the compose plugin
are installed, but there is no daemon and no `/var/run/docker.sock`, so the
first command fails with `Cannot connect to the Docker daemon` — which reads
like Docker is unavailable. It isn't. Start it with `bin/bootstrap_docker.sh`
(idempotent, safe at the top of any script).

**2. Containers can't reach the network the way the host does.** The session's
egress proxy re-terminates TLS and listens on `127.0.0.1` only, so a container
on the default bridge gets a certificate error from `gem install` and a
connection refused from `bundle install`. Both look like a broken network; both
are fixable.

Use the wrapper instead of `docker compose` directly — it starts the daemon,
installs the CA into the image, and puts the container in the host network
namespace:

```bash
bin/ccr_compose.sh build rails-8.0-large
bin/ccr_compose.sh up -d rails-8.0-large
docker exec woods-testbed-rails-8.0-large bash -lc 'cd /app && bin/rails woods:extract'
```

On a laptop the wrapper detects no proxy and passes straight through to
`docker compose`, so it is safe to use everywhere.

Two caveats under the overlay: `network_mode: host` **discards `ports:`**, so
the app binds directly on the host at 3000 and variants can't run side by side;
and `curl` to a container needs `--noproxy '*'` or it is sent to the proxy.

> Currently only `rails-8.0-large` carries the CA layer in its Dockerfile. The
> other three variants still fail to build behind the proxy — see §1.5 of
> [`docs/plans/002-large-app-variant.md`](docs/plans/002-large-app-variant.md).

Image pulls through the proxy work normally — no extra configuration needed.

## Layout

```
woods-testbed/
├── apps/
│   ├── rails-8.0/        Rails 8 variant (tutorial sample app)
│   ├── rails-7.2/        Rails 7.2 variant
│   ├── rails-6.0/        Rails 6.0 variant (supported floor, minimal)
│   ├── rails-8.0-large/  Rails 8 Canopy app + optional scale generator
│   └── rails-6.0-mysql/  Rails 6.0 + mysql2 dialect variant
├── bin/                  Host-side tooling: runs on your machine, not in a container
│   ├── bootstrap_docker.sh              # start the Docker daemon if it isn't running
│   └── ccr_compose.sh                   # docker compose wrapper for proxied sessions
├── docs/
│   └── plans/            Design + implementation plans, one per issue
├── scripts/              Shared smoke scripts (mounted at /app/script/shared)
│   ├── woods_smoke.rb
│   ├── woods_credentials_smoke.rb
│   ├── woods_contract_smoke.rb          # kernel contract (rails-8.0-large)
│   ├── woods_encoding_smoke.rb          # C-locale Index MCP executable contract
│   ├── woods_embedding_smoke.rb         # embedding pipeline against a backend
│   ├── woods_mysql_console_smoke.rb     # production-path MySQL Console SQL contract
│   ├── woods_worktree_smoke.rb          # git provenance in worktrees (#137)
│   ├── woods_extract_only_boot_smoke.rb # extract-only Index Server boot (#138)
│   ├── support/                         # shared helpers for smoke scripts
│   └── tools/                           # explicit lifecycle tests, generators, benchmarks
└── docker-compose.yml
```

Two directories, two audiences: top-level `scripts/*.rb` files run **inside** a
container via `bin/rails runner script/shared/…`, and everything in `bin/` runs
**on the host**. Tools under `scripts/tools/` are invoked explicitly. The
read-only bind mount only covers `scripts/`.

## Quick start

Default layout assumes `woods` and `woods-testbed` sit side by side:

```
~/somewhere/
├── woods/           # your woods gem checkout
└── woods-testbed/   # this repo
```

From inside `woods-testbed/`:

```bash
# Rails 8 (default port 3010)
docker compose up rails-8.0

# Rails 7.2 (default port 3011)
docker compose up rails-7.2

# Both at once
docker compose up

# Rails 6.0 + MySQL dialect variant (requires the backends profile)
docker compose --profile backends up -d mysql rails-6.0-mysql
```

The first boot of each variant installs gems into a named volume, which
can take a few minutes. Subsequent boots are cached.

### Pointing at a different woods checkout

Override the gem path with `WOODS_GEM_PATH` when your woods repo is
somewhere else or you're testing a worktree:

```bash
WOODS_GEM_PATH=/absolute/path/to/woods-feature-branch \
  docker compose up rails-8.0
```

### Changing ports

```bash
RAILS_8_PORT=4010 RAILS_72_PORT=4011 RAILS_60_PORT=4012 RAILS_8_LARGE_PORT=4013 RAILS_60_MYSQL_PORT=4014 docker compose up
```

`rails-6.0-mysql` is behind the `backends` profile, so `RAILS_60_MYSQL_PORT`
only matters when that profile/service is started. The app container still
listens on port 3000 internally; the variables above only change host ports.

## Running woods against a variant

With a variant running, extraction / MCP commands run through `docker
compose exec`:

```bash
# Rails 8 extraction + validation
docker compose exec rails-8.0 bin/rails woods:extract
docker compose exec rails-8.0 bin/rails woods:stats
docker compose exec rails-8.0 bin/rails woods:validate

# Same against Rails 7.2
docker compose exec rails-7.2 bin/rails woods:extract
docker compose exec rails-7.2 bin/rails woods:stats
```

Extraction output lands on the host under
`apps/rails-<version>/tmp/woods/` — the app directory is bind-mounted
read-write, so files written inside the container are visible to the
host and to editors.

## Running smoke scripts

The smoke scripts live in `scripts/` at the repo root. They're
version-agnostic: each prints the detected Rails version in its header
and skips cleanly when a variant lacks what it needs. Inside a container
they appear under `script/shared/`:

```bash
# Rails 8 smoke
docker compose exec rails-8.0 bin/rails runner script/shared/woods_smoke.rb
docker compose exec rails-8.0 bin/rails runner script/shared/woods_credentials_smoke.rb

# Rails 7.2 smoke
docker compose exec rails-7.2 bin/rails runner script/shared/woods_smoke.rb

# Git provenance in worktrees (#137) and extract-only Index Server boot (#138)
docker compose exec rails-8.0 bin/rails runner script/shared/woods_worktree_smoke.rb
docker compose exec rails-8.0 bin/rails runner script/shared/woods_extract_only_boot_smoke.rb

# Encoding executable contract (contract-first red until woods#247 lands)
docker compose exec rails-8.0 bin/rails runner script/shared/woods_encoding_smoke.rb

# MySQL Console dialect contract (requires rails-6.0-mysql + mysql; contract-first red until woods#248 lands)
docker compose exec rails-6.0-mysql bin/rails runner script/shared/woods_mysql_console_smoke.rb
```

All scripts exit non-zero on failure, which makes them suitable for
CI. `woods_worktree_smoke.rb` asserts `Woods::GitProvenance` reports `"unknown"`
for an unresolvable worktree git dir rather than a stale `GIT_BRANCH`/`GIT_SHA`.
`woods_extract_only_boot_smoke.rb` asserts the Index Server resolves in
pattern-only mode without an embedding index (and that `WOODS_REQUIRE_INDEX=1`
still fails closed).

For the isolated Puma watcher lifecycle test, including an installed `.gem`
mode and persistent MCP reader, see [Managed watcher acceptance](docs/WATCHER_ACCEPTANCE.md).

### Source-reference acceptance

The opt-in runner tests the unreleased #475 source-reference writer and #552
standalone-module discovery against a hand-labelled corpus in
`scripts/fixtures/source_references/`. Run it against an exact committed Woods
checkout:

```bash
ruby bin/woods_reference_acceptance.rb \
  --woods /absolute/path/to/woods --revision FULL_40_CHARACTER_SHA \
  --image woods-testbed-rails-8.0-large:latest --report-dir /tmp/reference-evidence
```

Use `--docker-sudo` when Docker requires `sudo -n`. Omit `--image` to build a
temporary Canopy image. For a built package, replace `--woods` with
`--gem /absolute/path/woods.gem --sha256 EXPECTED_SHA256`; `--revision` records
that artifact's expected source revision. Source mode archives committed bytes
and reports dirty working-tree changes as excluded. Artifact mode verifies both
the supplied digest and the activated installed package, without mounting Woods
source.

Each run creates a disposable app, bundle, SQLite database and index in its own
container. Fixture and harness inputs are frozen and mounted read-only. It never
starts or changes Compose services, application databases or shared bundle
volumes. The report directory must be new or empty; logs, input digests, loaded
gem identity and `acceptance.json` survive container cleanup.

Checks cover model callbacks, controller/service/PORO/library/concern callers,
qualified lexical resolution, string/comment and nested-owner negatives, target
arrival/deletion, caller edit/removal/rename, targeted refresh, concern changes,
singleton module lookup and inbound/outbound references, namespace-only exclusion,
includer-only PORO/concern ownership migration in both directions, and
failed-extraction publication isolation. Ownership changes leave the module file
unchanged and compare incremental output with a fresh full extraction.
One held-open packaged MCP process reads each generation; its supported JSON
renderer is configured before startup.
The pass/fail comparison retains every labelled fixture unit field, dependency
attributes, the complete typed graph (including variants and forward/reverse
edges), and candidate-cache ownership. Each cache HMAC is verified
with its own index's private key before key-dependent identities are excluded.
Incremental comparisons separately report dependents-order, type-index row-order
and six-decimal PageRank tolerances, matching Woods' existing equivalence oracle;
repeated full extraction checks strict fixture ordering. Strict whole-index
differences are also retained: existing Canopy controllers can serialize
action/chunk order differently across Ruby processes.
Supplying a baseline runs an independent full/full control to identify that
pre-existing limitation. Other unit families are not silently normalized.

For five alternating baseline/candidate pairs of full extraction, a leaf edit
and a shared-concern edit, add:

```bash
--baseline-woods /absolute/path/to/baseline --baseline-revision BASELINE_FULL_SHA \
--perf-reps 5 --timeout 3600
```

Measurements include extraction phase/wall times, process peak RSS, edge counts,
affected units and fixture traversal size. Rails boot is outside extraction
timings and inside peak RSS. Median overhead above 10% is a review trigger;
these small synthetic fixtures do not establish large-host performance. Without
a baseline, the report explicitly says performance was not run. Watch daemon
delivery remains a separate acceptance phase; this lane drives the incremental
and refresh writers directly.

Use `--failure-only` for a targeted repeat of the fixture baseline, live MCP
facts, failed-publication isolation and validation. The report names that subset;
it does not claim to rerun mutations or performance. Failure isolation compares
the generation pointer and every active-payload file's SHA256/tree entry without
the semantic equivalence normalizations above.

Add `--discovery-regressions` when the candidate includes the follow-up fixes for
Woods #558, #559, #562 and #563. The extra corpus checks class/module/library
Struct/Data wrappers, unchanged-caller references through value-class transitions,
schema lookup and source search, inherited/root-qualified/spaced resolvers,
multiple runtime schemas, and promotion of an existing object to a query root.
It exercises full, incremental and targeted-refresh publication through the same
held-open MCP reader, comparing each changed tree with a fresh full extraction.
The fixtures live in `scripts/fixtures/discovery_regressions/` and are introduced
**after** any performance matrix: the older baseline cannot publish those valid
wrappers, so including them in its timing corpus would prevent a matched comparison.
This option cannot be combined with `--failure-only`.

#### Recorded combined qualification — 2026-09-23

The final functional candidate, Woods
`0e2c3acf3d66708ac338f40d60f5c68875fa3445`, passed **51 source checks and 51
installed-gem checks**, including 20 equivalence comparisons in each lane, on
Ruby 3.3.1 / Rails 8.0.5.1. This includes the follow-up fix for successful model
provenance when an optional sibling model fails (Woods #568). The installed gem
used `Bundler::Source::Rubygems` without a Woods source mount; its SHA256 is
`82d183f8b524913a20c9a13e09a8f55b45e538305b9223993f60473a4328ae38`.
Performance was not repeated for this follow-up.

The earlier measured candidate `8f4cb336c28a5383a9ae0c29e88c22d9eb2c5ae0` passed **53 source
checks**, including the expanded discovery corpus and five alternating timing
pairs per scenario, on Ruby 3.3.1 / Rails 8.0.5.1. Its installed gem passed **51
functional checks** without a source mount. The artifact was first tested from
a byte-identical candidate tree and rebuilt from the PR revision with the same
SHA256: `81c940fccf7ccfa2c4373c0bc62aedfdf2527ece2ff76992b517acf3598a7415`.

The complete 30-sample timing run compared baseline
`ddd58961a887cee4a8f7d51a9ff344b1777202a7` with that combined candidate, using
matching non-Woods dependencies and no competing local test workload. Timings
measure the extraction call and exclude Rails/process boot:

| Scenario | Baseline median | Candidate median | Overhead |
| --- | ---: | ---: | ---: |
| Full extraction | 1521.833 ms | 1687.408 ms | +10.88% / 166 ms |
| Leaf edit | 723.185 ms | 881.334 ms | +21.87% / 158 ms |
| Shared-concern edit | 696.495 ms | 946.466 ms | +35.89% / 250 ms |

All three exceed the 10% review threshold, and their baseline/candidate ranges
do not overlap in this run. Nodes grew 419→422, edges 411→460, and the labelled
target's traversal grew 1→9; affected leaf/concern units remained 3/5. Median
process peak RSS increased about 2.3/5.4/2.7 MiB for full/leaf/concern.
Source-reference phase medians were 100/150/140 ms; incremental reconciliation
was 110/100 ms versus 70/70 ms. These are costs of the combined expansion;
they do not isolate a particular fix or establish large-host scaling. Woods
[#475](https://github.com/lost-in-the/woods/issues/475) retains that confirmation
before release. No edge or traversal cap was added to reduce these costs.

Labelled-unit and whole graph/cache equivalence passed under the comparison
contract above. Strict output retains the existing whole-index presentation-order
differences; this does not claim byte-identical whole indexes. Earlier timing
attempts and candidates are separate evidence, with no samples pooled into this
run. This qualification publishes no gem and changes no private host application.

## Interactive Rails console

```bash
docker compose exec rails-8.0 bin/rails console
docker compose exec rails-7.2 bin/rails console
```

## What each variant has

- **`rails-8.0` / `rails-7.2`:** the Rails Tutorial sample app models
  (`User`, `Micropost`, `Relationship`), plus a `Credential` model + seed
  fixtures used by `woods_credentials_smoke.rb` to exercise Console MCP
  redaction across real provider key shapes.
- **`rails-6.0`:** a minimal `Post`/`Comment` app (controller, job, mailer,
  routes) — **no** `User`/`Micropost`/`Relationship`/`Credential` models. See
  `apps/rails-6.0/README.md`.
- **`rails-8.0` / `rails-7.2` / `rails-6.0`:** an `app/services/domain/container/`
  wrapper-collision fixture (`Parser` and `Renderer`, both opening the same
  `Container` wrapper) for the woods G-1 identifier fix — each file must
  extract as the inner class, not the wrapper.
- **`rails-6.0-mysql`:** the same minimal Rails 6.0 shape with `mysql2`, a
  `User` table for Console SQL dialect probes, and no credential fixtures. See
  `apps/rails-6.0-mysql/README.md`.
- **All variants:** a `config/initializers/woods_console.rb` that enables
  Console MCP and a baseline set of redacted columns. The bearer token
  comes from `WOODS_CONSOLE_MCP_TOKEN` in `docker-compose.yml` (a fixed,
  test-only value). Without a token the gem refuses every Console MCP
  request with 401, so a bare `bin/rails server` outside compose has the
  endpoint enabled but inaccessible.

Agents have permission to modify anything under `apps/` — add models,
migrations, controllers, initializers, or fixtures as needed to
exercise gem functionality. The testbed exists to be reshaped.

## Troubleshooting

**Gems rebuild every boot.** The bundle volume is per-variant
(`woods-testbed-bundle-rails-8`, `woods-testbed-bundle-rails-7-2`,
`woods-testbed-bundle-rails-6-0`, `woods-testbed-bundle-rails-8-large`,
`woods-testbed-bundle-rails-6-0-mysql`).
Rebuilding shouldn't happen unless the `Gemfile.lock` changed — if it
does, check that the volume wasn't recreated.

**`WOODS_GEM_PATH` isn't being picked up.** Docker Compose resolves env
vars at `docker compose up` time, not `exec` time. Restart the service
after changing the env var: `docker compose down rails-8.0 && WOODS_GEM_PATH=... docker compose up rails-8.0`.

**Boot-time changes don't take effect.** Clear bootsnap cache inside
the container: `docker compose exec rails-8.0 rm -rf tmp/cache/bootsnap`.

### Extraction phase measurements

The opt-in `scripts/tools/woods_bench.rb` enables `WOODS_PROFILE` during each
measured extraction and records explicit phase durations, whole-run totals
when available, and raw profile lines for cold full and incremental samples.
Extraction wall time excludes Rails/process boot and mutation/reload setup.
The parser subtracts nested payload sync from legacy `publish` measurements;
newer disjoint profiles keep pointer publication and retention separate.
Unaccounted time includes uninstrumented work and per-line rounding. Older
gems without phase logging produce an empty phase map rather than guessed
stages. Run `ruby scripts/tools/woods_phase_logger_self_test.rb` to check the
parser without booting Rails.

For an isolated payload-seed comparison, run the opt-in clone benchmark:

```bash
WOODS_CLONE_BASELINE=/path/to/baseline/woods \
WOODS_CLONE_CANDIDATE=/path/to/candidate/woods \
WOODS_CLONE_BENCH_DIR=/path/on/the/index/filesystem \
  ruby scripts/tools/woods_payload_clone_bench.rb
```

It alternates both implementations over seven repetitions, verifies contents,
file identities and replacement isolation, and removes its generated tree.
Use `WOODS_CLONE_REPS` to change repetitions or `WOODS_CLONE_SOURCE` to clone an
existing payload read-only. Choose the actual persistent filesystem; tmpfs can
hide the cost. These are component timings, not whole-app performance claims.

### Source provenance in incremental comparisons

For Woods versions that publish `source_inputs.json`, the Canopy incremental
smoke also validates every captured identity with that output's private key.
Independent outputs use different HMAC keys: the oracle compares named source
versions, preserving per-consumer retained/current states and boot/runtime
coverage qualifications. It explicitly checks that an events-only refresh does
not certify an omitted dirty service. A supporting gem's missing artifact, wrong
key, malformed path, mismatched generation or unrecognized retained version fails
the check. Older Woods versions without the source-provenance capability retain
the existing structural comparisons.

`ruby scripts/tools/source_provenance_self_test.rb` tests the independent oracle
without Rails or the Woods bundle. Historical fixture bytes stay in memory; the
private key is never exported with a published payload.
