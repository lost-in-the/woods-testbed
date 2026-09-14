# Plan: turn the large variant into a working publishing platform

Status: implemented as the Canopy testbed; see [validation notes](../canopy-validation.md)
for shipped behavior, measured profiles, and remaining limits. The proposal below
records the original strategy; its counts/timings are estimates, not results.
The number is a document sequence, not a GitHub issue reference.

## Decision

Expand `apps/rails-8.0-large` into **Canopy**, a small publishing business app:
multiple publications, editorial review, paid subscriptions, newsletter
delivery, and customer support. Use ordinary Rails pages and forms, with a
small JSON/GraphQL surface sharing the same use cases. Keep SQLite and the
existing dependencies initially.

This extends the existing publishing/billing kernel rather than introducing
another app to maintain. Keep the smaller Rails and MySQL variants focused on
their compatibility contracts. Keep the synthetic source generator available
as an independent scale multiplier.

Success means a developer can follow a believable story through the UI and an
agent can answer questions about both its implementation and its records.

## What exists and what is missing

Inspection of the checked-in application found:

- Eight domain tables covering authors, articles, comments, tags, invoices,
  line items, and STI payments; two additional synthetic backing tables.
- A broad extraction kernel: concerns, policies, services, jobs, events,
  components, GraphQL, SQL view definitions, and a machine-readable contract.
- `db/seeds.rb` creates only one author and one article. The article has no
  `published_at`, so it does not populate the published article listing.
- `ArticlesController#create` exists but has no route. `RequiresAuthor` expects
  a session author, but the routes supply no sign-in flow.
- `PublishArticle` creates an already-published article and enqueues a mail
  job. Billing exists separately; the described publishing-to-billing chain
  is not implemented by that job.
- The source generator multiplies classes over two shared tables. This is
  useful for extraction scale, but does not create a varied business schema.
- The large variant README still describes a scaffold and placeholder models;
  it is stale relative to the code and completed scale plan.

Woods' structural index represents runtime code, schema, and relationships;
the Console server provides access to application records. Increasing row
counts alone does not increase structural coverage. Treat code complexity,
record volume, and extraction quality as separate dimensions.

## Functional scope and data model

Target **30 domain tables and approximately 32 ActiveRecord classes**, including
the existing payment subclasses. Counts are planning estimates, not acceptance
criteria. Every table must support a workflow, a report, or a specific contract.

| Area | Models / tables | Purpose and relationships |
|---|---|---|
| Access and ownership | `Organization`, `Publication`, `Membership` | Organizations own publications; authors join organizations through role-bearing memberships. |
| Editorial | Existing `Author`, `Article`, `Comment`, `Tag`, `ArticleTag`; new `ArticleRevision`, `ReviewAssignment`, `ReviewDecision`, `Collection`, `CollectionArticle` | Publications own articles and ordered collections; revisions preserve content; assignments connect reviewers to revisions and decisions record outcomes. |
| Commerce | `Subscriber`, `Billing::Plan`, `Billing::Subscription`, `Billing::SubscriptionChange`; existing `Billing::Invoice`, `Billing::LineItem`, `Billing::Payment`; new `Billing::Refund` | Subscribers buy publication plans; subscriptions have change histories and invoices; invoices have items and payment attempts; refunds belong to captured payments. |
| Audience | `Newsletter::Campaign`, `Newsletter::Delivery`, `EngagementEvent` | Campaigns feature articles; deliveries join campaigns to subscribers; events record opens, clicks, and article reads. |
| Support | `Support::Ticket`, `Support::TicketMessage` | Subscriber tickets have optional author assignees, threaded messages, and an optional reference to an invoice or subscription. |
| Operations | `ActivityEvent`, `WebhookEndpoint`, `WebhookDelivery` | Audit history references actors and polymorphic subjects; organizations own endpoints with retryable deliveries. |

Retain `Author` as the editorial identity so the current kernel remains
recognizable. `Subscriber` is a separate customer identity with an optional
author link. Keep `Billing::Invoice#author` as the responsible staff member;
add explicit subscriber and subscription associations for the billed customer.
Keep existing payment STI and methods unless an intentional contract migration
requires changing them.

Use real constraints: foreign keys, required fields, unique membership and
article-tag pairs, unique delivery/idempotency keys, and indexes supporting the
actual reports. Money uses integer cents and an explicit currency; the demo
uses one currency and has no exchange-rate logic. Preserve line-item price
snapshots when plans change.

Include these relationship shapes deliberately:

- `has_many :through` with attributes: membership roles and collection order.
- Self-reference: comment replies with an optional parent comment; reject cycles
  and parents belonging to another article.
- Polymorphism: activity subjects and ticket references; validate their allowed
  types and ownership because a conventional foreign key cannot enforce them.
- STI: existing card/bank payment subclasses with different fake outcomes.
- Versioning: immutable article revisions and review decisions tied to the
  reviewed revision, so approval cannot silently apply to new content.
- Enums/state machines, optional associations, counter caches, timestamps,
  soft archival, text, and nested JSON metadata used by real screens.
- Explicit organization scoping through ownership relationships; validate that
  authors, plans, subscribers, and linked records belong to the right context.

## Workflows that make the structure useful

1. **Enter a publication.** Select a seeded demo identity, choose an organization,
   and see an editorial dashboard scoped by membership. The identity selector
   is available only in development/test; editor and author roles have distinct
   permitted actions, enforced by policies on the server.
2. **Draft and review.** Create/edit a draft, save a revision, assign a reviewer,
   request changes, resubmit, and approve a specific revision. Show validation
   errors and history on the article page.
3. **Publish.** Publish an approved revision now or schedule it, then run the due
   publishing job. Render the public article, update its collection, invalidate
   relevant caches, and record an activity event. A retry must not publish twice.
4. **Subscribe and bill.** Choose a publication plan, activate a subscription,
   issue an invoice, and simulate successful or failed payment. Retry a failed
   attempt and demonstrate partial refund and cancellation. Publishing itself
   does not charge readers; subscription activation and renewal issue invoices.
5. **Send a newsletter.** Select published articles, preview recipients, enqueue
   deliveries, and simulate delivered/bounced outcomes and engagement. Repeating
   a job must not create duplicate recipient deliveries.
6. **Resolve support work.** Open a ticket for a failed renewal, link the invoice,
   assign staff, exchange messages, and resolve it. Navigate back to the invoice
   and subscriber history.
7. **Inspect operations.** Show overdue invoices, renewal failures, review backlog,
   campaign outcomes, audit history, and simulated webhook retries.

Use server-rendered ERB, pagination, filters, and simple forms. Finish these
journeys before adding UI polish. Reuse existing components where they fit.
Expose article lookup and one editorial mutation through GraphQL after the HTML
workflow works, with identical authorization and use-case behavior.

Mail uses a local/test delivery adapter. Payment, newsletter delivery, and
webhook transport use deterministic in-process fakes; no external accounts or
services are required. Jobs have explicit test execution and a documented local
drain/due-work command, so async behavior is observable and repeatable.

## Seed strategy

Commit curated scenario definitions and a deterministic record generator under
`db/seeds/` and `lib/testbed/`. Keep these outside source-generator cleanup paths.
Use a fixed PRNG seed, configurable reference time, stable business keys, and a
versioned manifest of counts and expected results. Synthetic identities use
reserved example domains. Article bodies and support threads should describe
the same events represented by their related records.

| Profile | Proposed scale | Use |
|---|---|---|
| `smoke` | 2 organizations, 3 publications, 12 authors, 30 articles, 60 subscribers; about 1,000 total records | Required CI, all named scenarios, organization isolation. |
| `demo` | 5 organizations, 12 publications, 80 authors, 600 articles, 2,000 subscribers; about 50,000 records | Default local exploration and application reports. |
| `stress` | 25 organizations, 75 publications, 500 authors, 10,000 articles, 25,000 subscribers; about 500,000 records | Opt-in query/serialization benchmarks. |

Totals are initial budgets; delivery and event counts are explicitly capped so
subscriber-by-campaign multiplication cannot silently exceed them. Adjust after
measuring seed time and storage.

Every profile contains named, fixed scenarios: rejected then approved revision,
scheduled article, empty publication, anonymous reply, archived discussion,
failed then successful renewal, partially refunded invoice, canceled subscription,
bounced newsletter, unassigned support ticket, and retried webhook. Include
Unicode, multiline text, null optional fields, duplicate display names across
organizations, and a bounded large JSON/text record.

Use skewed distributions: one busy publication, several quiet ones, popular
articles with many replies, and customers with unequal activity. Add fixed
date-boundary cases and active/inactive histories. Keep valid business edge cases
in the demo; attempted invalid records belong in tests.

Seed reruns must neither duplicate nor erase interactive edits. Upsert only
seed-owned records using stable keys, skip edited scenarios with an explicit
report, and use a separate explicit reset task for a fresh fixture database.
In CI, seed fresh databases at a fixed reference time and assert invariant
counts and independently specified report answers. Local demo time may be
anchored to the run date, recorded in the manifest.

## What to assert about Woods

Add a `functional_contract.yml` alongside `kernel_contract.yml`, and a shared
`woods_functional_smoke.rb` that skips variants lacking that contract. Keep
structural and Console checks distinct. Use stable names/business keys rather
than auto-increment IDs; do not derive expected answers from extracted output.

| Probe | Required evidence |
|---|---|
| Article model inspection | Schema, publication/author/revision associations, validations, state, scopes, and included concern behavior are present. |
| Publication workflow | Expected route, controller, policy, use case, model, job, and mailer units and supported dependency edges can be retrieved. |
| Change impact | Editing an editorial concern refreshes its expected includers; unrelated billing units retain equivalent semantic content. |
| Relationship complexity | Through associations, comment self-reference, activity polymorphism, and namespaced payment STI preserve their distinct identities. |
| Execution flow | The publish entry point exposes the supported static flow relationships; separately execute the workflow to verify runtime effects. |
| Console reports | Queries return the fixed review backlog, overdue invoice totals, newsletter outcomes, and subscriber support history. |
| Serialization/redaction | Nested JSON, Unicode, nullable relations, bounded results, and synthetic sensitive columns obey the Console contract. |
| Retrieval | Curated questions retrieve the expected units for review approval, payment retry, newsletter eligibility, and ticket ownership. |

Run structural retrieval without embeddings as the mandatory lane. Keep semantic
retrieval optional with a pinned provider/model and fixture version, recording
top-k recall against the curated expected units. Do not make external provider
availability a requirement for application tests.

Maintain the kernel's exact concern-includer expectations. Add separate domain
concerns when appropriate or deliberately update the contract with an explained
behavioral change. Recheck existing known-issue entries against the tested gem
revision; do not silently widen allowlists to make new fixtures pass.

For incremental checks, mutate and restore files in a disposable checkout and
boot a fresh Rails process where needed, following `woods_flows_smoke.rb`.
Compare normalized units/edges with clean full extraction, excluding generation
IDs and timing fields. Test additions, changes, and removals. Unsupported gem
behavior gets a small reproducible contract failure, not fabricated output.

## Implementation sequence

| Phase | Work | Exit condition |
|---|---|---|
| 1. Working baseline | Record gem SHA and current contract results; repair stale app documentation, demo session entry, article forms/routes, cache behavior, and published seeds. | A fresh container can browse and create an article; existing smokes retain their baseline results. |
| 2. Editorial slice | Add organizations, publications, memberships, revisions, review assignments/decisions, collections, and replies; implement policies and editorial screens. | Draft → changes requested → approved revision → published works, including invalid transition and cross-organization rejection tests. |
| 3. Commerce slice | Add subscribers, plans, subscriptions/history, invoice associations, refunds, fake payment outcomes, and renewal jobs. | Activation, failed renewal/retry, cancellation, and partial refund work; transaction/retry tests prevent duplicate charges or invoices. |
| 4. Audience and support | Add campaigns, deliveries, engagement, tickets/messages, activity, fake webhooks, and useful dashboard queries. | Newsletter and support journeys work; ownership and idempotency checks pass. |
| 5. Reproducible dataset | Expand seed profiles and fixture manifest; implement explicit reset and report verification. | Repeated fresh seeds reproduce logical data and expected reports; rerunning seeds preserves user edits; every scenario exists in smoke. |
| 6. Extraction acceptance | Add functional contract, retrieval questions, Console reports, incremental equivalence, and CI integration. | Smoke profile passes application and Woods checks; artifacts include gem/testbed SHAs and fixture version. |
| 7. Scale calibration | Measure demo/stress data and existing generated-source presets independently and in selected combinations. | Publish repeatable timing/memory/results and set regression budgets from the measured baseline. |

Each slice includes its migrations, small seed scenarios, UI, business tests,
and extraction assertions. Phase 5 consolidates and scales those scenarios;
phase 6 joins the accumulated checks into the shared harness. Phase 2 is the
first useful delivery; all seven phases complete this proposal.

Add migrations rather than rewriting historical migrations. Backfill existing
records into a default organization/publication before enforcing new required
ownership fields. Preserve old fixture identities and extraction identifiers.
Validate both empty-database setup and upgrading the current kernel database.

## Validation and maintenance

- Run app request/model/job tests on `smoke`, then full extraction, validation,
  existing kernel smokes, and the functional contract. Include policy-denied
  requests, stale revision approval, retry duplication, refund limits, and
  organization isolation; fixture size alone is not a passing test.
- CI currently runs every top-level shared smoke on every variant. Make the new
  script's skip explicit and seed only the large variant. Preserve the existing
  extraction/permission-proof ordering when adding generation-mutating checks.
- Record source-unit counts excluding framework units, edge/association coverage,
  seed rows, seed duration, extraction duration, incremental duration, daemon
  memory, report latency, and deterministic query results separately.
- Keep source scale (`WOODS_GEN_SCALE`) independent from a proposed data-profile
  setting (`TESTBED_DATA_PROFILE`). Establish new benchmark baselines because
  expanding the kernel changes the workload; retain old results with their SHAs.
- Keep handwritten domain code out of `*/generated` directories: the existing
  generator removes those directories when regenerating or cleaning.
- Deliver updated quick-start instructions, a short demo walkthrough, an ER
  diagram, seed/reset commands, and example Woods questions with expected answers.

Defer full production authentication, real payment/email integrations, elaborate
frontend tooling, attachment storage, and a new PostgreSQL app variant. These can
be separate fixtures if a concrete gem regression later requires them. The
first objective is connected behavior and reproducible evidence, not operating
a production publishing business.
