# woods-testbed

Host Rails apps used to exercise the [woods](https://github.com/lost-in-the/woods)
gem against a real, booted Rails environment. The gem can't be fully
validated by unit tests alone — extraction, the Console MCP server, and
the ERD middleware all require a live Rails boot with models, routes,
and a database.

This repo carries **one Rails app per supported Rails version**. They're
minimal forks of the [Rails Tutorial sample app](https://github.com/mhartl/sample_app_6th_ed)
with the woods gem wired in and a handful of woods-specific smoke
scripts that assert behavioural invariants.

## Variants

| Variant | Rails | Ruby | Port | Container |
|---|---|---|---|---|
| `apps/rails-8.0` | 8.0.x | 3.3.1 | 3010 | `woods-testbed-rails-8.0` |
| `apps/rails-7.2` | ~> 7.2.0 | 3.3.1 | 3011 | `woods-testbed-rails-7.2` |

Each variant has its own `Gemfile`, its own bundle volume, and its own
container. The two share `scripts/` (woods smoke scripts) via a read-only
bind mount at `/app/script/shared` inside the container.

Contributing a new Rails version: copy an existing `apps/rails-X.Y`
directory, edit the Gemfile pin, add a new service to
`docker-compose.yml`, and update the table above.

## Prerequisites

- Docker + Docker Compose (v2)
- A local checkout of the [woods gem](https://github.com/lost-in-the/woods)

## Layout

```
woods-testbed/
├── apps/
│   ├── rails-8.0/        Rails 8 variant (tutorial sample app)
│   └── rails-7.2/        Rails 7.2 variant
├── scripts/              Shared smoke scripts (mounted at /app/script/shared)
│   ├── woods_smoke.rb
│   └── woods_credentials_smoke.rb
├── share/                Shared snippets (initializers, seeds) referenced by apps
└── docker-compose.yml
```

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
RAILS_8_PORT=4010 RAILS_72_PORT=4011 docker compose up
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

Two smoke scripts live in `scripts/` at the repo root. They're
version-agnostic — each prints the detected Rails version in its
header. Inside a container they appear under `script/shared/`:

```bash
# Rails 8 smoke
docker compose exec rails-8.0 bin/rails runner script/shared/woods_smoke.rb
docker compose exec rails-8.0 bin/rails runner script/shared/woods_credentials_smoke.rb

# Rails 7.2 smoke
docker compose exec rails-7.2 bin/rails runner script/shared/woods_smoke.rb
```

Both scripts exit non-zero on failure, which makes them suitable for
CI.

## Interactive Rails console

```bash
docker compose exec rails-8.0 bin/rails console
docker compose exec rails-7.2 bin/rails console
```

## What each variant has

- The Rails Tutorial sample app models (`User`, `Micropost`,
  `Relationship`)
- A `Credential` model + seed fixtures used by
  `woods_credentials_smoke.rb` to exercise Console MCP redaction across
  real provider key shapes
- A `config/initializers/woods_console.rb` that enables Console MCP, ERD
  middleware, and a baseline set of redacted columns

Agents have permission to modify anything under `apps/` — add models,
migrations, controllers, initializers, or fixtures as needed to
exercise gem functionality. The testbed exists to be reshaped.

## Troubleshooting

**Gems rebuild every boot.** The bundle volume is per-variant
(`woods-testbed-bundle-rails-8`, `woods-testbed-bundle-rails-7-2`).
Rebuilding shouldn't happen unless the `Gemfile.lock` changed — if it
does, check that the volume wasn't recreated.

**`WOODS_GEM_PATH` isn't being picked up.** Docker Compose resolves env
vars at `docker compose up` time, not `exec` time. Restart the service
after changing the env var: `docker compose down rails-8.0 && WOODS_GEM_PATH=... docker compose up rails-8.0`.

**Boot-time changes don't take effect.** Clear bootsnap cache inside
the container: `docker compose exec rails-8.0 rm -rf tmp/cache/bootsnap`.
