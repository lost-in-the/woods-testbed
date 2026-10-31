# Contributor payouts and syndication: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Payouts::` and `Syndication::` domains to Canopy (`apps/rails-8.0-large`) as ordinary, tested Rails code.

**Architecture:** Foundation (schema, models, tenant plumbing, lib code) lands first in one session. Payouts workflows and Syndication workflows then build in parallel on disjoint files. UI follows. Seeds and contracts close it out.

**Tech Stack:** Rails 8.0, SQLite, RSpec, aasm, Pundit, Phlex, graphql-ruby. No new gems.

**Spec:** [`004-contributor-payouts-syndication.md`](004-contributor-payouts-syndication.md)

## Global Constraints

- All app paths below are relative to `apps/rails-8.0-large/`.
- **Rails commands run in the container**, never on the host. Specs: `podman exec canopy-payouts-dev canopy-rspec <paths>`. The wrapper runs `db:prepare` against `/scratch/test.sqlite3` and writes `tmp/test_results.json`. Read that file for failures; do not re-run to see them.
- Migrations: `podman exec canopy-payouts-dev bash -lc 'cd /app && DATABASE_URL=sqlite3:/scratch/development.sqlite3 bin/rails db:migrate'` regenerates `db/schema.rb`.
- **Do not include `Archivable`, `Auditable`, or `RequiresAuthor` anywhere new.** The kernel contract asserts their includer counts exactly.
- **Do not change existing smoke report answers** (`functional_contract.yml` `smoke_reports`).
- Every new record validates that its parts belong to one organization, in the style of `Billing::Subscription` and `WebhookDelivery`.
- Money is integer cents in `*_cents` columns with a `currency` string column defaulting to `'USD'`.
- No em-dashes in code comments or docs. Comments only where the existing code would have one (why, not what).
- No AI attribution in commits.
- Match existing idioms: use cases are POROs with `call`, editors are checked with `author.editor_of?(organization)` and raise `Pundit::NotAuthorizedError`, invalid transitions raise `ArgumentError` or `ActiveRecord::RecordInvalid`.

## Review Focus

1. **A second payout run for the same month** must return the existing run and build nothing. Pinned in Task 3.
2. **Publishing an article whose author has no payee** (editors, unpaid staff) must publish normally and accrue nothing. Pinned in Task 3.
3. **A partner token for a suspended partner, or a revoked license id,** must get 401 or 404, never another partner's data. Pinned in Task 4.
4. **An agency-represented author** must never get a second, individual payee in that organization. Pinned in Task 2.
5. **A transient provider failure after the database lock** must leave the transfer retryable and never double-pay. Pinned in Task 3.

---

### Task 1: Tenant plumbing, settings, encryption, and lib code

**Files:**
- Create: `app/models/current.rb`
- Create: `app/controllers/concerns/current_tenant.rb`
- Modify: all 11 controllers under `app/controllers/` (one `include CurrentTenant` line each, next to any existing include)
- Create: `config/payouts.yml`
- Modify: `config/application.rb` (one line: `config.payouts = config_for(:payouts)`)
- Create: `config/initializers/active_record_encryption.rb`
- Create: `lib/canopy/money_columns.rb`, `lib/canopy/royalty_calculator.rb`
- Test: `spec/lib/canopy/royalty_calculator_spec.rb`, `spec/lib/canopy/money_columns_spec.rb`, `spec/requests/current_tenant_spec.rb`

**Interfaces:**
- Produces:
  - `Current < ActiveSupport::CurrentAttributes` with attributes `organization`, `author`, `partner`.
  - `CurrentTenant` concern: `before_action :assign_current_tenant`, which sets `Current.author = current_author` and `Current.organization = current_organization`. Relies only on those two methods.
  - `Rails.configuration.payouts`: `minimum_payout_cents: 2500`, `syndication_author_share_bps: 5000`, `transfer_retry_attempts: 3` (under `shared:`).
  - `Canopy::MoneyColumns`: `ActiveSupport::Concern` with class method `money_column(cents_attribute)`. It validates the attribute as an integer `>= 0` and defines `#{name without _cents}_display` returning `"$12.00 USD"` style strings via `Canopy::MoneyColumns.format(cents, currency)`.
  - `Canopy::RoyaltyCalculator.new(rate_card: nil, settings: Rails.configuration.payouts)`:
    - `#article_fee_cents(word_count:) -> Integer`: `per_word` is `word_count * cents_per_word`, raised to `minimum_cents` when set; `flat` is `flat_cents`; `revenue_share` is `0`.
    - `#syndication_share_cents(fee_cents:) -> Integer`: `fee_cents * syndication_author_share_bps / 10_000`, rounded down.
    - `#breakdown(earnings) -> Array<Hash>`: one `{ kind:, count:, gross_cents: }` per earning kind, sorted by kind.
    - Reads `rate_card.basis` and `rate_card.cents_per_word / flat_cents / minimum_cents` (defined in Task 2). Specs use a `Struct` double until then.

- [ ] **Step 1: Write the failing tests**
  - `royalty_calculator_spec.rb`: `per_word` with 300 words at 4 cents is 1200; with `minimum_cents: 2000` it is 2000; `flat` with `flat_cents: 5000` is 5000; `revenue_share` is 0; `syndication_share_cents(fee_cents: 10_001)` is 5000; `breakdown` of two `article_fee` and one `syndication_share` doubles returns two hashes with counts 2 and 1.
  - `money_columns_spec.rb`: `Canopy::MoneyColumns.format(123_456, 'USD')` is `"$1,234.56 USD"`; a model class built with `Class.new(ApplicationRecord) { self.table_name = 'billing_line_items'; include Canopy::MoneyColumns; money_column :amount_cents }` is invalid with `amount_cents: -1`.
  - `current_tenant_spec.rb`: after `Rails.application.eager_load!`, every subclass of `ActionController::Base` defined under `app/controllers` includes `CurrentTenant` (except `ApplicationController` itself); and a request that logs in as `@editor` and hits an action sees `Current.organization == @organization` (spy with `allow_any_instance_of(ArticlesController).to receive(:index).and_wrap_original`).
- [ ] **Step 2: Run them; expect `NameError` for `Canopy::RoyaltyCalculator`, `Canopy::MoneyColumns`, `CurrentTenant`.**
- [ ] **Step 3: Implement the files above.** Encryption keys: `ActiveRecord::Encryption.configure` (or `config.active_record.encryption.*`) from `ENV.fetch('CANOPY_ENCRYPTION_*')` with fixed, testbed-only defaults; a comment says never reuse them, like the compose tokens.
- [ ] **Step 4: Run `canopy-rspec`; expect the full suite (36 old + new) to pass.**
- [ ] **Step 5: Commit** `Add tenant plumbing, payout settings, and money helpers to Canopy`.

### Task 2: Schema, models, and the earning ledger writer

**Files:**
- Create: `db/migrate/20261031000001_create_payouts_and_syndication.rb`; regenerate `db/schema.rb`
- Create: `app/models/payouts/{payee,individual_profile,agency_profile,representation,rate_card,earning,payout_run,statement,transfer,bank_transfer,international_bank_transfer,wallet_transfer}.rb`
- Create: `app/models/concerns/payouts/profile.rb` (`Payouts::Profile`, included by both profile models: `has_one :payee, as: :profile, touch: true`)
- Create: `app/models/syndication/{partner,license,usage_report}.rb`
- Modify: `app/models/organization.rb`, `publication.rb`, `article.rb`, `author.rb` (inverse `has_many`s only)
- Create: `app/use_cases/payouts/accrue_earning.rb`
- Create: `config/routes/payouts.rb`, `config/routes/syndication.rb` (bare route DSL with a one-line comment and no routes yet; `config/routes.rb` calls `draw(:payouts)` and `draw(:syndication)` before `root`)
- Test: `spec/models/payouts_models_spec.rb`, `spec/models/syndication_models_spec.rb`, `spec/use_cases/payouts/accrue_earning_spec.rb`

**Schema** (all tables have `timestamps`; `null: false` unless marked optional):

| Table | Columns | Indexes |
|---|---|---|
| `payouts_payees` | `organization` ref, `profile_type`, `profile_id`, `display_name`, `status` int default 0, `payout_method` string default `'bank'`, `country_code` string default `'US'`, `currency` default `'USD'` | unique `[profile_type, profile_id]` |
| `payouts_individual_profiles` | `author` ref, `legal_name`, `tax_id` (optional), `bank_details` json default `{}` | |
| `payouts_agency_profiles` | `name`, `contact_email` | |
| `payouts_representations` | `agency_profile` ref, `author` ref | unique `[agency_profile_id, author_id]` |
| `payouts_rate_cards` | `publication` ref, `basis` int, `terms` json default `{}`, `effective_on` date | unique `[publication_id, effective_on]` |
| `payouts_earnings` | `payee` ref, `source_type`, `source_id`, `kind` int, `amount_cents` int, `currency`, `earned_on` date, `statement` ref optional, `description` | unique `[payee_id, source_type, source_id, kind]` named `index_payouts_earnings_on_source_identity` |
| `payouts_payout_runs` | `organization` ref, `period_start` date, `status` int default 0, `statements_count` int default 0, `started_by` ref to authors, `finalized_at` optional | unique `[organization_id, period_start]` |
| `payouts_statements` | `payout_run` ref, `payee` ref, `status` int default 0, `total_cents` int default 0, `currency`, `hold_reason` optional | unique `[payout_run_id, payee_id]` |
| `payouts_transfers` | `type`, `statement` ref (unique), `state` string, `amount_cents`, `currency`, `idempotency_key` (unique), `attempts` int default 0, `provider_reference` optional, `last_error` optional, `destination` json default `{}` | |
| `syndication_partners` | `organization` ref, `name`, `contact_email`, `api_token` (unique), `webhook_secret` optional, `status` int default 0 | |
| `syndication_licenses` | `partner` ref, `article` ref, `granted_by` ref to authors, `territory`, `starts_on` date, `ends_on` date, `exclusive` bool default false, `fee_cents`, `currency`, `revoked_at` optional | `[article_id, territory]` |
| `syndication_usage_reports` | `license` ref, `period_start` date, `pickups` int default 0, `impressions` int default 0, `reported_at` datetime | unique `[license_id, period_start]` |

All foreign keys to namespaced tables need explicit `to_table:` (repo precedent in `20260914000001_create_canopy.rb`).

**Model decisions:**
- `Payouts::Payee`: `delegated_type :profile, types: %w[Payouts::IndividualProfile Payouts::AgencyProfile]`; `enum :status, { active: 0, paused: 1 }`; `validates :payout_method, inclusion: { in: %w[bank international_bank wallet] }`; `scope :in_current_organization, -> { where(organization: Current.organization) }`; `self.for_author(author, organization) -> Payee | nil` returns the agency payee if a representation for that author exists under an agency payee in that organization, else the author's individual payee there, else nil. Validation: an individual payee is invalid when the author is represented by an agency payee in the same organization.
- `Payouts::IndividualProfile`: `encrypts :tax_id, deterministic: true`; `normalizes :tax_id, with: ->(v) { v.gsub(/\D/, '') }`; `store_accessor :bank_details, :account_last_four, :iban_last_four, :swift_code, :wallet_handle, :simulate_timeout`.
- `Payouts::AgencyProfile`: `has_many :representations`, `has_many :authors, through: :representations`; `accepts_nested_attributes_for :representations`; `normalizes :contact_email, with: ->(e) { e.strip.downcase }`.
- `Payouts::Representation`: invalid when the author already has an individual payee in the agency payee's organization, or is not a member of it.
- `Payouts::RateCard`: `enum :basis, { per_word: 0, flat: 1, revenue_share: 2 }`; `store_accessor :terms, :cents_per_word, :flat_cents, :minimum_cents` (cast to integers in readers); `self.current_for(publication, on:) -> RateCard | nil` is the latest `effective_on <= on`.
- `Payouts::Earning`: `include Canopy::MoneyColumns; money_column :amount_cents`; `enum :kind, { article_fee: 0, syndication_share: 1 }`; `belongs_to :source, polymorphic: true` with `validates :source_type, inclusion: { in: %w[Article Syndication::License] }`; `belongs_to :statement, optional: true`; `scope :unclaimed, -> { where(statement_id: nil) }`.
- `Payouts::PayoutRun`: `enum :status, { drafted: 0, finalized: 1, completed: 2 }`; `has_many :statements` with `counter_cache` on the statement side; `validate` that `period_start` is the first of a month.
- `Payouts::Statement`: `include Canopy::MoneyColumns; money_column :total_cents`; `enum :status, { draft: 0, held: 1, finalized: 2, paid: 3 }`; `has_many :earnings, dependent: :nullify`; `has_one :transfer`; payee and run must share an organization.
- `Payouts::Transfer` (STI base, `self.table_name = 'payouts_transfers'`): `include AASM`, `include Canopy::MoneyColumns; money_column :amount_cents`; aasm column `state`: states `pending` (initial), `failed`, `settled`, `rejected`; events `fail` (pending, failed to failed), `settle` (pending, failed to settled), `reject` (pending, failed to rejected). `after_commit :enqueue_submission, on: :create` calls `Payouts::SubmitTransferJob.perform_later(id)` (job defined in Task 3; guard with `defined?` is not acceptable, so Task 2 adds an empty `Payouts::SubmitTransferJob < ApplicationJob` with `queue_as :payouts` and a `perform(transfer_id)` that does nothing yet). `self.class_for(payout_method) -> Class` maps `bank`, `international_bank`, `wallet` to the three subclasses.
- `Payouts::BankTransfer < Transfer`: `store_accessor :destination, :account_last_four`. `Payouts::InternationalBankTransfer < BankTransfer`: adds `:iban_last_four, :swift_code`, validates both present. `Payouts::WalletTransfer < Transfer`: `:wallet_handle`, validates present.
- `Syndication::Partner`: `has_secure_token :api_token`; `encrypts :webhook_secret, deterministic: true`; `normalizes :contact_email` (strip, downcase); `enum :status, { active: 0, suspended: 1 }`; `has_many :licenses`.
- `Syndication::License`: `include Canopy::MoneyColumns; money_column :fee_cents`; `default_scope { where(revoked_at: nil) }`; `belongs_to :granted_by, class_name: 'Author', default: -> { Current.author }`; `scope :active_on, ->(date) { where('starts_on <= ? AND ends_on >= ?', date, date) }`; validations: article is published, article and partner share an organization, `ends_on >= starts_on`, and **no overlapping exclusive conflict**: for the same article, any other unrevoked license whose window overlaps and whose territory is equal or either side is `'worldwide'`, where this or that one is exclusive.
- `Syndication::UsageReport`: belongs to license; `validates :pickups, :impressions, numericality: { greater_than_or_equal_to: 0 }`.
- `Payouts::AccrueEarning#call(payee:, source:, kind:, amount_cents:, earned_on:, description:) -> Payouts::Earning | nil`: returns nil when `amount_cents` is zero; raises `ArgumentError, 'Source belongs to another organization'` on mismatch; writes with `Payouts::Earning.insert_all([...], unique_by: :index_payouts_earnings_on_source_identity)` and returns the stored row via `find_by!`.

**Interfaces:**
- Consumes: Task 1 (`Current`, `Canopy::MoneyColumns`).
- Produces: every model and method named above; `Payouts::AccrueEarning`; `config/routes/payouts.rb` and `config/routes/syndication.rb` (empty DSL files, drawn).

- [ ] **Step 1: Write the failing specs**
  - `payouts_models_spec.rb`: `for_author` prefers the agency payee; individual payee invalid for a represented author; representation invalid for an author with an individual payee; `tax_id` is stored encrypted (raw `SELECT tax_id` differs from `'123456789'`) and `find_by(tax_id: '123-45-6789')` finds it; `contact_email` normalizes `' Desk@Agency.TEST '` to `'desk@agency.test'`; `RateCard.current_for` picks the newest effective card; `InternationalBankTransfer.superclass == BankTransfer` and it requires `iban_last_four`; creating a transfer enqueues `Payouts::SubmitTransferJob` once **after commit** (`have_enqueued_job`); a statement with a payee from another organization is invalid.
  - `syndication_models_spec.rb`: license for an unpublished article is invalid; two overlapping exclusive licenses for the same article and territory are invalid; a non-exclusive `US` license overlapping an exclusive `worldwide` one is invalid; non-overlapping windows are valid; a revoked license is absent from `Syndication::License.all` and present in `unscoped`; `granted_by` defaults to `Current.author`; partner `api_token` is generated on create.
  - `accrue_earning_spec.rb`: two identical calls create one earning; zero cents returns nil and creates nothing; a source from another organization raises `ArgumentError`.
- [ ] **Step 2: Run; expect `NameError` / missing table failures.**
- [ ] **Step 3: Write the migration, run it, check `git diff db/schema.rb` shows additions only (`gen_hubs`, `gen_records` stay).**
- [ ] **Step 4: Implement the models, `AccrueEarning`, the placeholder job, the two route files, and the `draw` lines.**
- [ ] **Step 5: Run the full suite; expect everything to pass.**
- [ ] **Step 6: Commit** `Add payouts and syndication schema and models`.

### Task 3: Payouts workflows (parallel with Task 4)

**Files (owned exclusively by this task):**
- Create: `app/use_cases/payouts/{accrue_article_earning,start_payout_run,finalize_payout_run,submit_transfer}.rb`
- Create: `app/clients/payouts/fake_ledger_client.rb`
- Modify: `app/jobs/payouts/submit_transfer_job.rb` (from Task 2)
- Create: `app/jobs/payouts/{monthly_payout_run_job,reconcile_transfers_job}.rb`
- Create: `app/listeners/payouts_listener.rb`, `config/initializers/event_listeners.rb`
- Create: `app/mailers/contributor_mailer.rb`, `app/views/contributor_mailer/statement_ready.{html,text}.erb`
- Modify: `config/recurring.yml` (add `monthly_payout_run` `"0 6 1 * *"` and `reconcile_transfers` `"15 * * * *"`)
- Test: `spec/use_cases/payouts/*_spec.rb`, `spec/jobs/payouts/submit_transfer_job_spec.rb`

**Interfaces:**
- Consumes: Task 1 and Task 2 interfaces.
- Produces:
  - `Payouts::AccrueArticleEarning#call(article) -> Earning | nil`: nil when no payee or no rate card; amount from `RoyaltyCalculator#article_fee_cents(word_count: article.word_count)`; `kind: :article_fee`, `earned_on: article.published_at.to_date`.
  - `PayoutsListener.subscribe!`: subscribes to `article.published`, calls `AccrueArticleEarning` for `Article.find(payload[:article_id])`. Wired once with `Rails.application.config.after_initialize`.
  - `Payouts::StartPayoutRun.new(author:).call(organization:, period_start:) -> PayoutRun`: editor only; normalizes to the first of the month; **builds statements only when the run is newly created**; each payee with unclaimed earnings `earned_on < period_start.next_month` gets a statement; total below `minimum_payout_cents` makes it `held` with `hold_reason: 'below_minimum'` and **claims no earnings**; otherwise `draft` and claims them (`update_all(statement_id:)`).
  - `Payouts::FinalizePayoutRun.new(author:).call(run) -> PayoutRun`: editor only; under `run.with_lock`; no-op when already finalized; each draft statement becomes `finalized`, gets one transfer of `Transfer.class_for(payee.payout_method)` with `idempotency_key: "statement-#{statement.id}"` and destination copied from the individual profile's bank details (agency payees use `account_last_four: '7000'`); sends `ContributorMailer.statement_ready(statement).deliver_later`.
  - `Payouts::FakeLedgerClient#create_transfer(idempotency_key:, amount_cents:, currency:, destination:, attempt:) -> { reference:, status: 'settled' }`; raises `Payouts::FakeLedgerClient::Rejected` when `destination['account_last_four'] == '0000'`; raises `Payouts::FakeLedgerClient::TransientError` on `attempt == 1` when `destination['simulate_timeout']` is truthy; reference is `"ldg_" + SHA256(idempotency_key)[0, 12]`.
  - `Payouts::SubmitTransfer#call(transfer, client: FakeLedgerClient.new) -> Transfer`: under `transfer.with_lock`; no-op when settled or rejected; increments `attempts`; settled marks the statement `paid` and the run `completed` when no statement is `finalized`; `TransientError` calls `fail!`, stores `last_error`, re-raises; `Rejected` calls `reject!` and sets the statement `held` with `hold_reason: 'transfer_rejected'`.
  - `Payouts::SubmitTransferJob`: `retry_on Payouts::FakeLedgerClient::TransientError, wait: 5.minutes, attempts: Rails.configuration.payouts[:transfer_retry_attempts]`; `discard_on ActiveRecord::RecordNotFound`.
  - `Payouts::MonthlyPayoutRunJob#perform(at = Time.current)`: for each organization, its first editor starts the run for the previous month.
  - `Payouts::ReconcileTransfersJob#perform`: re-enqueues `SubmitTransferJob` for each `failed` transfer.
  - `ContributorMailer.statement_ready(statement)`: to the individual author's email, or the agency `contact_email`.

- [ ] **Step 1: Write failing specs** with these names and assertions:
  - `publishing twice accrues one article earning` (`PublishArticle` twice with a payee and per-word rate card; `Payouts::Earning.count` changes by 1).
  - `publishing for an author without a payee accrues nothing`.
  - `a second run for the same month builds nothing` (`StartPayoutRun` twice; `PayoutRun.count` by 1, `Statement.count` by 1).
  - `a statement below the minimum is held and its earnings roll into next month` (held statement, earnings `statement_id` nil, next month's run claims them).
  - `finalizing creates one transfer per draft statement and is idempotent`.
  - `a timeout fails the first attempt and the retry settles once` (`simulate_timeout: '1'`; first `SubmitTransfer` raises and leaves `failed`; second settles; `provider_reference` set; statement `paid`; run `completed`).
  - `a rejected destination holds the statement` (`account_last_four: '0000'`).
  - `the job retries transient errors` (`perform_enqueued_jobs` with `Payouts::SubmitTransferJob`, final state `settled`, `attempts == 2`).
  - `an author cannot start a payout run` (raises `Pundit::NotAuthorizedError`).
- [ ] **Step 2: Run; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite; expect all pass.**
- [ ] **Step 5: Commit** `Add payout runs, statements, and transfers`.

### Task 4: Syndication workflows and partner API (parallel with Task 3)

**Files (owned exclusively by this task):**
- Create: `app/use_cases/syndication/{grant_license,revoke_license,record_usage}.rb`
- Create: `app/jobs/syndication/import_usage_report_job.rb`
- Create: `app/controllers/api/base_controller.rb`, `app/controllers/api/v1/licenses_controller.rb`, `app/controllers/api/v2/licenses_controller.rb`, `app/controllers/api/v2/usage_reports_controller.rb`
- Create: `app/serializers/syndication/license_serializer.rb`, `app/serializers/syndication/v2/license_serializer.rb`, `app/serializers/syndication/usage_report_serializer.rb`
- Modify: `config/routes/syndication.rb` (API routes only in this task)
- Modify: `app/models/activity_event.rb` (add `'Syndication::License'` to the subject inclusion list and its organization branch)
- Test: `spec/use_cases/syndication/*_spec.rb`, `spec/requests/partner_api_spec.rb`

**Interfaces:**
- Consumes: Task 1 and Task 2 interfaces, including `Payouts::AccrueEarning` and `Payouts::Payee.for_author`.
- Produces:
  - `Syndication::GrantLicense.new(author:).call(partner:, article:, territory:, starts_on:, ends_on:, fee_cents:, exclusive: false) -> License`: editor of the partner's organization only; creates the license; records activity `license.granted` via `RecordActivity`; accrues a `syndication_share` earning for `Payee.for_author(article.author, organization)` with `RoyaltyCalculator.new.syndication_share_cents(fee_cents:)` (skipped when no payee).
  - `Syndication::RevokeLicense.new(author:).call(license) -> License`: editor only; sets `revoked_at`; accrued earnings stay.
  - `Syndication::RecordUsage#call(partner:, rows:) -> Integer`: each row `{ license_id:, period_start:, pickups:, impressions: }`; every `license_id` must be in `partner.licenses` (default scope excludes revoked) or raise `ActiveRecord::RecordNotFound`; `UsageReport.upsert_all(..., unique_by: [:license_id, :period_start])`; returns row count.
  - `Syndication::ImportUsageReportJob#perform(partner_id, rows)` (queue `:syndication`) calls `RecordUsage`.
  - `Api::BaseController < ActionController::API`: `include ActionController::HttpAuthentication::Token::ControllerMethods`, `include CurrentTenant`; `before_action :authenticate_partner!` (runs **before** `assign_current_tenant`); 401 JSON `{ error: 'unauthorized' }` for missing, unknown, or suspended partners; `current_author` returns nil; `current_organization` returns the partner's organization; sets `Current.partner`; `rescue_from ActiveRecord::RecordNotFound` gives 404 JSON `{ error: 'not_found' }`.
  - Routes: `GET /api/v1/licenses`, `GET /api/v1/licenses/:id`, `GET /api/v2/licenses`, `GET /api/v2/licenses/:id`, `POST /api/v2/usage_reports`.
  - v1 JSON: `{ "licenses": [ { id, territory, starts_on, ends_on, exclusive, article: { title, slug, body } } ] }`, active on today only.
  - v2 JSON: `{ "data": [ v1 fields plus usage: [UsageReportSerializer] ], "meta": { "count": n } }`; `POST /api/v2/usage_reports` with `{ reports: [...] }` enqueues `ImportUsageReportJob` and returns 202 `{ accepted: n }`.

- [ ] **Step 1: Write failing specs** with these names:
  - `granting a license accrues the author's syndication share once`.
  - `granting a license for an agency-represented author pays the agency`.
  - `an author cannot grant a license`.
  - `a revoked license keeps its earning and leaves the API`.
  - `usage reports upsert by license and period` (two posts for one period leave one row with the latest counts).
  - `usage for another partner's license is refused`.
  - Request specs: `v1 lists only the partner's active licenses`; `v2 wraps data and includes usage`; `missing or suspended tokens get 401`; `another partner's license id gets 404`; `v2 usage post returns 202 and enqueues the import`.
- [ ] **Step 2: Run; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite; expect all pass.**
- [ ] **Step 5: Commit** `Add syndication licenses and the partner API`.

### Task 5: Payouts and syndication pages (after Tasks 3 and 4)

**Files:**
- Create: `app/components/application_component.rb` (`ApplicationComponent < Phlex::HTML`), `app/components/money_component.rb`, `app/components/status_badge_component.rb`, `app/components/payouts/statement_row_component.rb`
- Create: `app/controllers/payouts/{payees,payout_runs,statements}_controller.rb`, `app/controllers/syndication/{partners,licenses}_controller.rb` (each includes `CurrentTenant`)
- Create: `app/policies/payouts/statement_policy.rb` (Pundit shape: `show?` for editors of the organization, the individual payee's author, or an author the agency represents; `index?` for editors)
- Create: `app/serializers/payouts/statement_serializer.rb`
- Create: views under `app/views/payouts/` and `app/views/syndication/`
- Modify: `config/routes/payouts.rb`; `config/routes/syndication.rb` (add the `namespace :syndication` UI routes below the API routes)
- Modify: `app/views/layouts/application.html.erb` (editor nav: `Payouts`, `Syndication`)
- Create: `app/graphql/types/statement_type.rb`; Modify: `app/graphql/types/query_type.rb` (`payout_statement(id: ID!)`, scoped to `Current.organization`, authorized with `StatementPolicy#show?`)
- Test: `spec/requests/payouts_pages_spec.rb`, `spec/requests/syndication_pages_spec.rb`

**Interfaces:**
- Routes: `resources :payees, only: %i[index show create]`, `resources :payout_runs, only: %i[index show create] { member { post :finalize } }`, `resources :statements, only: :show` under `namespace :payouts`; `resources :partners, only: %i[index show create]`, `resources :licenses, only: :create { member { post :revoke } }` under `namespace :syndication`.
- `Payouts::StatementsController#show`: authorizes with `StatementPolicy`; **when `params[:preview] == '1'`** it sets `@breakdown = Canopy::RoyaltyCalculator.new.breakdown(@statement.earnings)`; responds to `format.json` with `Payouts::StatementSerializer`.
- `Payouts::PayeesController#create` takes `kind=individual` (author, legal name, tax id, payout method, bank details) or `kind=agency` (name, contact email, `representations_attributes`).

- [ ] **Step 1: Write failing request specs:** every new index and show page returns 200 for an editor; authors get 403 on payees and payout runs; an author sees their own statement and gets 404 or 403 for another payee's; `?preview=1` renders the breakdown table; the JSON statement matches the serializer; creating an agency with two nested representations creates two rows; finalize from the UI creates transfers; granting and revoking a license from the partner page works; GraphQL `payoutStatement` returns the total for an editor and an error for another organization.
- [ ] **Step 2: Run; expect failures.**
- [ ] **Step 3: Implement.** Components render money with `MoneyComponent` and status with `StatusBadgeComponent`; both subclass `ApplicationComponent`.
- [ ] **Step 4: Run the full suite; expect all pass.**
- [ ] **Step 5: Commit** `Add payouts and syndication pages`.

### Task 6: Seeds, contracts, and docs (main session)

**Files:**
- Modify: `lib/testbed/dataset.rb`, `scripts/tools/canopy_dataset_check.rb` (row bound), `functional_contract.yml`, `kernel_contract.yml`, `README.md` (variant), `docs/canopy-validation.md`, root `README.md` if it states table counts
- Test: `canopy-rspec`; `bin/rails testbed:seed` on a fresh smoke DB; `script/shared/tools/canopy_dataset_check.rb`; `bin/rails woods:extract`; `script/shared/woods_contract_smoke.rb`; `script/shared/woods_functional_smoke.rb`

- [ ] **Step 1:** In `build_organizations`, after authors: one individual payee per non-editor author except every 6th (agency-represented, two agencies, `CANOPY-AGENCY` names one); a per-word rate card per publication (4 cents, minimum 1500) and a flat card on the empty publication; payee for author with `account_last_four: '0000'` once (rejection), `simulate_timeout: '1'` once.
- [ ] **Step 2:** Add `build_syndication` and `build_payouts` after `build_audience`. Syndication: two partners per organization with explicit `api_token`s, licenses for some published stories (`canopy-story-3` exclusive worldwide), one revoked, usage reports. Payouts: run for the reference month's previous month, finalize, call `Payouts::SubmitTransferJob.perform_now` explicitly (twice for the timeout payee). Scenario keys: `held_statement`, `agency_payee`, `exclusive_license`, `retried_transfer`.
- [ ] **Step 3:** Add the 12 tables to `TABLES`, bump `VERSION` to 2, seed a fresh smoke DB, measure totals, widen the dataset check bound, run the dataset check.
- [ ] **Step 4:** Add payouts answers to `functional_contract.yml` (models, units, two retrieval probes, `smoke_reports` per organization: held statement count and paid cents, computed independently from the seed rules) and the new concerns to `kernel_contract.yml` (with the woods#175 known-issue entry for `CurrentTenant`). Run extract plus both smokes.
- [ ] **Step 5:** Update READMEs and validation notes with measured counts.
- [ ] **Step 6: Commit** `Seed and document Canopy payouts and syndication`.
