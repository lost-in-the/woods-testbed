# woods-testbed

Host Rails apps used to exercise the [woods](https://github.com/lost-in-the/woods)
gem against a real, booted Rails environment. The gem can't be fully
validated by unit tests alone: extraction and the Console MCP server
both require a live Rails boot with models, routes, and a database.

This repo carries **one Rails app per supported Rails version**. They're
minimal forks of the [Rails Tutorial sample app](https://github.com/mhartl/sample_app_6th_ed)
with the woods gem wired in and a handful of woods-specific smoke
scripts that assert behavioural invariants.

## Variants

| Variant | Rails | Ruby | Port | Container |
|---|---|---|---|---|
| `apps/rails-8.0` | 8.0.x | 3.3.1 | 3010 | `woods-testbed-rails-8.0` |
| `apps/rails-7.2` | ~> 7.2.0 | 3.3.1 | 3011 | `woods-testbed-rails-7.2` |
| `apps/rails-6.0` | ~> 6.0.0 | 3.0 | 3012 | `woods-testbed-rails-6.0` |
| `apps/rails-8.0-large` | 8.0.x | 3.3.1 | 3013 | `woods-testbed-rails-8.0-large` |

The 8.0 and 7.2 variants are minimal forks of the Rails Tutorial sample app.
The **rails-6.0** variant — the supported floor (`railties >= 6.0`, woods #135)
— is a deliberately minimal, backend-only app (`Post`/`Comment`, a controller, a
job, a mailer; no asset pipeline or JS bundler) so the Rails 6.0 boot stays small.
It's validated via Docker/CI rather than the host, since Ruby 3.0 / Rails 6.0
aren't installed on most dev machines.

The **rails-8.0-large** variant is a large synthetic app for scale
benchmarks (incremental latency, whole-app re-run cost, daemon memory). It
exists to measure scale, not version behaviour, and is the only variant
whose `Dockerfile` runs `db:prepare` at boot.

Each variant has its own `Gemfile`, its own bundle volume, and its own
container. They share `scripts/` (woods smoke scripts) via a read-only
bind mount at `/app/script/shared` inside the container.

Contributing a new Rails version: copy an existing `apps/rails-X.Y`
directory, edit the Gemfile pin, add a new service to
`docker-compose.yml`, and update the table above.

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
│   └── rails-8.0-large/  Rails 8 scale variant (synthetic, benchmarks)
├── bin/                  Host-side tooling: runs on your machine, not in a container
│   ├── bootstrap_docker.sh              # start the Docker daemon if it isn't running
│   └── ccr_compose.sh                   # docker compose wrapper for proxied sessions
├── docs/
│   └── plans/            Design + implementation plans, one per issue
├── scripts/              Shared smoke scripts (mounted at /app/script/shared)
│   ├── woods_smoke.rb
│   ├── woods_credentials_smoke.rb
│   ├── woods_contract_smoke.rb          # kernel contract (rails-8.0-large)
│   ├── woods_embedding_smoke.rb         # embedding pipeline against a backend
│   ├── woods_worktree_smoke.rb          # git provenance in worktrees (#137)
│   ├── woods_extract_only_boot_smoke.rb # extract-only Index Server boot (#138)
│   └── tools/                           # generator + benchmark (not run by CI)
└── docker-compose.yml
```

Two directories, two audiences: everything in `scripts/` runs **inside** a
container via `bin/rails runner script/shared/…`, and everything in `bin/` runs
**on the host**. The read-only bind mount only covers `scripts/`.

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
RAILS_8_PORT=4010 RAILS_72_PORT=4011 RAILS_60_PORT=4012 RAILS_8_LARGE_PORT=4013 docker compose up
```

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
```

All scripts exit non-zero on failure, which makes them suitable for
CI. `woods_worktree_smoke.rb` asserts `Woods::GitProvenance` reports `"unknown"`
for an unresolvable worktree git dir rather than a stale `GIT_BRANCH`/`GIT_SHA`.
`woods_extract_only_boot_smoke.rb` asserts the Index Server resolves in
pattern-only mode without an embedding index (and that `WOODS_REQUIRE_INDEX=1`
still fails closed).

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
- **All variants:** a `config/initializers/woods_console.rb` that enables
  Console MCP and a baseline set of redacted columns. No
  `console_mcp_token` is set, so the gem warns at boot and serves the
  Console MCP endpoint unauthenticated. That is deliberate for a
  throwaway testbed; never copy the initializer into a real app.

Agents have permission to modify anything under `apps/` — add models,
migrations, controllers, initializers, or fixtures as needed to
exercise gem functionality. The testbed exists to be reshaped.

## Troubleshooting

**Gems rebuild every boot.** The bundle volume is per-variant
(`woods-testbed-bundle-rails-8`, `woods-testbed-bundle-rails-7-2`,
`woods-testbed-bundle-rails-6-0`, `woods-testbed-bundle-rails-8-large`).
Rebuilding shouldn't happen unless the `Gemfile.lock` changed — if it
does, check that the volume wasn't recreated.

**`WOODS_GEM_PATH` isn't being picked up.** Docker Compose resolves env
vars at `docker compose up` time, not `exec` time. Restart the service
after changing the env var: `docker compose down rails-8.0 && WOODS_GEM_PATH=... docker compose up rails-8.0`.

**Boot-time changes don't take effect.** Clear bootsnap cache inside
the container: `docker compose exec rails-8.0 rm -rf tmp/cache/bootsnap`.
