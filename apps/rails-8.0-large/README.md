# Canopy — Rails 8 functional and scale testbed

Canopy is a fictional publishing business for testing Woods against connected
Rails behavior and meaningful records. It has 29 domain tables, payment STI,
editorial revisions/reviews, subscription billing, newsletters, support, and
activity/webhook history. The smaller variants retain their compatibility role.

## Start and explore

From the repository root:

```bash
docker compose up -d --build rails-8.0-large
docker compose exec rails-8.0-large bin/rails testbed:seed
```

Open **http://localhost:3013**, choose **Editor 1**, and enter the publishing desk.
A fresh database defaults to the `demo` profile. The explicit seed command also
covers an existing database that `db:prepare` has already migrated.

1. **Editorial:** create a story, save a revision, choose an editor, and submit.
   Switch to that editor to request changes or approve the current revision.
   Publish immediately or schedule in UTC, then use **Run due work** when due.
   **Collections** lets editors order stories and attach tags.
2. **Subscribers:** add a reader, activate a plan, and inspect the new invoice.
   Simulate a decline, retry successfully, and issue a partial refund. Cancel a
   subscription to exclude it from future renewals and newsletter recipients.
3. **Newsletters:** select a published story, preview eligibility, send, and
   finish queued deliveries, and record a simulated click on delivered messages.
   Some seeded readers opt out or simulate a bounce.
4. **Support:** open a ticket from a subscriber, optionally link an invoice,
   add staff replies, assign an editor, and resolve it.
5. **Overview:** inspect the review backlog, overdue totals, newsletter outcomes,
   activity history, and local webhook attempts. First webhook attempts fail;
   retries succeed. A delivered webhook is not delivered again.

Authors can edit their own unpublished work and read published work within their
organization. Editors handle review, finance, newsletter, and support actions.
The demo identity selector is available only in development/test. Public stories
have a separate `/read/:slug` page. This is a local demo, not production auth.

All payments, mail, newsletter delivery, and webhook transport are local fakes
or test adapters. No external service account is needed. Due jobs can also run
with `bin/rails testbed:drain`; async queues are not durable across restarts.

## Data profiles

| Profile | Authors | Articles | Subscribers | Engagement events | Approximate total rows |
|---|---:|---:|---:|---:|---:|
| `smoke` | 12 | 30 | 60 | 120 | 940 |
| `demo` | 80 | 600 | 2,000 | 25,000 | 46,000 |
| `stress` | 500 | 10,000 | 25,000 | 200,000 | 480,000 |

The seed retains existing kernel records, so an upgraded database may have a
few additional records. Every profile includes the same named scenarios:
`canopy-story-0` was rejected then approved, `canopy-story-1` is scheduled,
`CANOPY-OVERDUE` has 2,500 cents due, and `CANOPY-REFUND` has a 300-cent partial
refund. The empty publication, anonymous threaded comment, archived discussion,
canceled subscribers, nested preferences, Unicode text, and unassigned ticket
provide useful boundary cases.

The default reference time is `2026-09-14T12:00:00Z`. Override
`TESTBED_REFERENCE_TIME` for a new dataset if you want scheduled work relative to
another date. The PRNG seed and fixture version are fixed in
`lib/testbed/dataset.rb`. The manifest records profile, clock, counts, seed time,
and a fingerprint in `tmp/canopy_dataset_development.json` (or `_test.json`).

**Seed reruns skip the existing dataset and preserve edits.** A different profile
requires a fresh database. To intentionally erase and rebuild this variant:

```bash
docker compose exec -e TESTBED_DATA_PROFILE=smoke -e CONFIRM=reset-canopy \
  rails-8.0-large bin/rails testbed:reset
```

To keep the interactive database while building a benchmark profile:

```bash
docker compose exec \
  -e DATABASE_URL=sqlite3:/app/tmp/canopy-demo.sqlite3 \
  -e TESTBED_MANIFEST_PATH=tmp/canopy_demo_benchmark.json \
  -e TESTBED_DATA_PROFILE=demo \
  rails-8.0-large bin/rails db:schema:load testbed:seed
```

Use a new filename per disposable database; `db:schema:load` replaces its tables.
Repeat the same database/manifest environment for report and benchmark commands.

## Validate

```bash
docker compose exec -e RAILS_ENV=test rails-8.0-large bin/rails db:prepare
docker compose exec rails-8.0-large bundle exec rspec
docker compose exec rails-8.0-large bin/rails woods:extract
docker compose exec rails-8.0-large bin/rails woods:validate
docker compose exec rails-8.0-large bin/rails runner script/shared/woods_contract_smoke.rb
docker compose exec rails-8.0-large bin/rails runner script/shared/woods_functional_smoke.rb
docker compose exec rails-8.0-large bin/rails runner script/shared/tools/canopy_incremental_check.rb
```

The functional smoke requires seeded records. Its fixed aggregate report checks
apply to a fresh `smoke` dataset; interactive edits that change those answers
should use a disposable smoke database for acceptance testing. The seed checker
(`script/shared/tools/canopy_dataset_check.rb`) requires smoke and proves reruns
preserve a temporary edit inside a rolled-back transaction.

The incremental checker makes a disposable source copy, reuses the selected
read-only database workload, and verifies concern fan-out, unchanged billing
metadata, equivalence with full extraction, and class addition/removal.

CI selects smoke for the large variant, runs its application/seed/incremental
checks, then runs the shared smokes. Smaller variants skip the functional contract.

## Ask Woods useful questions

- Where is approval tied to a particular article revision? `EditorialWorkflow`.
- What can publishing enqueue, and which models include `Archivable`?
  `PublishArticle`, `PublishArticleJob`, `Article`, `Comment`, `Billing::Invoice`.
- What prevents duplicate payment attempts? `Billing::CollectPayment`.
- Which subscriptions qualify for newsletters? `Newsletter::Campaign#recipients`
  and `Newsletter::SendCampaign`.
- How is a support ticket constrained to its subscriber? `Support::Ticket`.
- How much of invoice `CANOPY-REFUND` was refunded? Console joins return 300 cents.
- What happened between the two revisions of `canopy-story-0`? Console joins show
  `changes_requested`, then `approved`.

`functional_contract.yml` stores expected units, relationships, retrieval probes,
and independent smoke report answers. Structural retrieval requires no embeddings.
Semantic retrieval remains an optional use of the existing embedding harness.
The GraphQL endpoint is `POST /graphql`, authenticated by the same demo session
and CSRF protection as the HTML forms. `publishArticle(id: ...)` uses the same
publishing policy and transition checks.

## Source scale and record scale

The committed application/kernel supplies real behavior. The existing source
multiplier remains optional:

```bash
# Run in a disposable checkout: these commands generate source and mutate it.
docker compose exec -e WOODS_GEN_SCALE=small rails-8.0-large \
  ruby script/shared/tools/generate_large_app.rb
docker compose exec rails-8.0-large bin/rails db:prepare
docker compose exec rails-8.0-large bin/rails runner script/shared/tools/woods_bench.rb

# Read-only record/report benchmark (requires extraction and a seed manifest):
docker compose exec rails-8.0-large bin/rails runner script/shared/tools/canopy_bench.rb
```

Generated files live under the real `app/*/generated` directories, plus
`db/generated` and `config/routes_generated.rb`. Keep handwritten domain code
outside those paths: generator cleanup removes them. `WOODS_GEN_SCALE` controls
source families; `TESTBED_DATA_PROFILE` controls rows. Neither substitutes for
the other. Benchmark timings are descriptive and hardware-dependent; use repeated
runs on the same machine before setting a latency gate.

See [the implementation plan](../../docs/plans/003-functional-publishing-app.md)
and [validation notes](../../docs/canopy-validation.md) for the measured baseline,
limits, and entity diagram.
