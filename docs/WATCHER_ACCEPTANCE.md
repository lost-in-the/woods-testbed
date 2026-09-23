# Managed watcher acceptance

This focused test starts the Rails 8 Canopy fixture with Puma, drives filesystem
changes, and keeps one Index MCP reader connected across those changes. It is
run explicitly from CI; it does not belong in the shared Rails-runner smoke loop.
Tracking: [testbed #32](https://github.com/lost-in-the/woods-testbed/issues/32).

## Run a source revision

Requirements: Ruby on the host, Git, tar, and a running Docker daemon. The
container installs its own isolated bundle. Start from the testbed checkout:

```bash
ruby bin/woods_watch_acceptance.rb \
  --woods /absolute/path/to/woods \
  --revision 922d52438407bf32cbd25b713491156955bc5df9 \
  --report-dir /tmp/woods-watcher-source
```

`--revision` must be the checkout's full HEAD SHA. The runner mounts a snapshot
of that commit under `/woods-gem`; uncommitted and ignored files are excluded.
The fixture also comes from the testbed's committed HEAD. The runner freezes a
copy of the working harness before starting, so local harness edits can be
exercised before a commit. Evidence includes both checkout dirty states, the
runner digest, a per-file harness SHA256 manifest, and fixture/source archive
digests. Review the harness diff when sharing uncommitted results.

The report directory must be new or empty. Omit `--report-dir` to get a retained
temporary directory. For a daemon requiring local sudo, add `--docker-sudo`
(`sudo -n docker`). `--docker /path/to/docker` accepts one executable path, not
a shell command. An existing image built from the Canopy Dockerfile can be
selected with `--image woods-testbed-rails-8.0-large:latest`; otherwise the runner
builds and removes its own uniquely named image.

## Run an installed package

Supply the exact artifact, its expected SHA256, and its source revision:

```bash
ruby bin/woods_watch_acceptance.rb \
  --gem /absolute/path/to/woods-2.0.0.gem \
  --sha256 EXPECTED_64_CHARACTER_SHA256 \
  --revision EXPECTED_40_CHARACTER_SOURCE_REVISION \
  --report-dir /tmp/woods-watcher-artifact
```

A digest mismatch fails before Docker is invoked. The digest is checked again
inside the container. Artifact mode installs the supplied package into the
isolated bundle and pins its exact version in the disposable Gemfile. There is
no `/woods-gem` mount. The harness verifies that the activated gem's package
cache file has the expected SHA256 and rejects checkout load-path fallback.
Package metadata does not reliably contain a commit SHA:
the expected source revision is provenance supplied by the caller, not a claim
that the harness recovered that revision from the package.

CI builds a candidate package directly from the selected `woods_ref` and runs
both source and artifact modes. Such a build validates packaging and the test
harness; it is **not final 2.0 release validation**. Once the prepared final gem
and expected digest exist, run against those exact bytes. Release preparation,
tagging, publication, and the broader upgrade/rollback acceptance are outside
this watcher test.

## Isolation and evidence

Each invocation creates a unique container with no published ports or shared
volumes. It copies the committed Canopy fixture into the container, uses a fresh
SQLite database, `/bundle`, and `/scratch/index`, and supplies `BUNDLE_PATH` via
the environment. Developer databases, local `.bundle/config`, generated files,
and existing indexes are excluded. It uses no Compose services. Its finalizer
stops and removes only its own container and image, including after failures.
An image explicitly supplied with `--image` is preserved.

The runner retains `runner.json`, `runner.log`, and the harness's JSON and logs
in the printed report directory, including on test failure. Bootstrap errors
appear in `runner.log` even if the harness could not start. A cleanup error makes
the runner fail and is recorded in `runner.json`. Container lifetime defaults
to 1,800 seconds including dependency installation; adjust with `--timeout`.
Individual harness waits also have deadlines and retain diagnostics.
The runner requires a nonempty, all-PASS harness report with the requested
mode and revision; a successful Docker command alone cannot pass this lane.

The focused assertions cover setup/update ownership and idempotence, unchanged
lockfile and bundle configuration during generator operations, stopped-file
catch-up, create/edit/delete through one live MCP connection, initializer
restart, Puma availability, watcher ownership, and shutdown. Content lookup
proves convergence; a changed generation number alone is insufficient.

The Rails 6.0 fixture retains its Puma 4.3 pin and extraction coverage. Its CI
job explicitly runs `scripts/tools/woods_watch_unsupported_smoke.rb` with
`bundle exec ruby`. This invokes the actual generator, requires a nonzero exit
and the supported-Puma diagnostic, and verifies that Puma config, wrapper,
receipt, Gemfile/lockfile, and application/active Bundler configuration remain
unchanged. Its JSON and generator log are uploaded as
`watcher-unsupported-puma`. Unexpected writes are reported as failures and
restored before later extraction tests. Managed Puma mode supports Puma 6/7/8;
the floor fixture is never silently upgraded or counted as a passed lifecycle
test.

## CI and helper checks

```bash
ruby scripts/tools/mcp_session_self_test.rb
gh workflow run ci.yml --repo lost-in-the/woods-testbed \
  --ref YOUR_TESTBED_BRANCH \
  -f woods_ref=922d52438407bf32cbd25b713491156955bc5df9
```

The managed-watcher source/artifact jobs upload `watcher-source` and
`watcher-artifact` evidence. The ordinary variant matrix remains separate so
watcher coverage cannot hide an extraction regression.
