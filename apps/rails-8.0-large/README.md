# rails-8.0-large

Scale variant for [woods-testbed#2](https://github.com/lost-in-the/woods-testbed/issues/2):
the app used to measure incremental latency, whole-app re-run cost, and daemon
memory at a size where those numbers mean something.

Rails 8.0 only. It exists to measure **scale**, not version behaviour — the
version matrix is `rails-8.0` / `rails-7.2` / `rails-6.0`'s job.

## Two layers

- **Kernel** (committed): one idiomatic instance of every unit type the gem
  extracts. Hand-written, because the fixture for "does concern inlining work"
  needs to be readable. See `KERNEL_CONTRACT.md` for the naming scheme every
  kernel file conforms to.
- **Generated** (gitignored): `app/generated/`, `db/generated/`, produced by
  `scripts/generate_large_app.rb` at a chosen scale. Reproducible from the
  generator, so it is not committed.

## Current state

Scaffold only — 149 units, of which 120 are `rails_source`. The kernel and the
generator are rungs 3–9 of
[`docs/plans/002-loop.md`](../../docs/plans/002-loop.md).

`Account` / `AccountEvent` are placeholders that exist so extraction has
something to chew on. The kernel contract supersedes them; don't build on them.

## Running it

From the repo root, behind a proxy (Claude Code web/app):

```bash
bin/ccr_compose.sh up -d rails-8.0-large
```

On a laptop:

```bash
docker compose up -d rails-8.0-large      # port 3013
```

Then:

```bash
docker exec woods-testbed-rails-8.0-large bash -lc 'cd /app && bin/rails woods:extract'
docker exec woods-testbed-rails-8.0-large bash -lc 'cd /app && bin/rails woods:validate'
```
