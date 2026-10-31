# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_10_31_000001) do
  create_table "activity_events", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "actor_id"
    t.string "subject_type", null: false
    t.integer "subject_id", null: false
    t.string "action", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_activity_events_on_actor_id"
    t.index ["organization_id"], name: "index_activity_events_on_organization_id"
    t.index ["subject_type", "subject_id"], name: "index_activity_events_on_subject"
  end

  create_table "article_revisions", force: :cascade do |t|
    t.integer "article_id", null: false
    t.integer "author_id", null: false
    t.integer "number", null: false
    t.string "title", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id", "number"], name: "index_article_revisions_on_article_id_and_number", unique: true
    t.index ["article_id"], name: "index_article_revisions_on_article_id"
    t.index ["author_id"], name: "index_article_revisions_on_author_id"
  end

  create_table "article_tags", force: :cascade do |t|
    t.integer "article_id", null: false
    t.integer "tag_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id", "tag_id"], name: "index_article_tags_on_article_id_and_tag_id", unique: true
    t.index ["article_id"], name: "index_article_tags_on_article_id"
    t.index ["tag_id"], name: "index_article_tags_on_tag_id"
  end

  create_table "articles", force: :cascade do |t|
    t.integer "author_id", null: false
    t.string "title", null: false
    t.string "slug", null: false
    t.text "body"
    t.datetime "published_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "publication_id", null: false
    t.string "state", default: "draft", null: false
    t.datetime "scheduled_at"
    t.integer "lock_version", default: 0, null: false
    t.integer "comments_count", default: 0, null: false
    t.index ["author_id"], name: "index_articles_on_author_id"
    t.index ["publication_id", "state", "scheduled_at"], name: "index_articles_on_publication_id_and_state_and_scheduled_at"
    t.index ["publication_id"], name: "index_articles_on_publication_id"
    t.index ["slug"], name: "index_articles_on_slug", unique: true
    t.check_constraint "comments_count >= 0", name: "articles_comment_count_nonnegative"
  end

  create_table "authors", force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_authors_on_email", unique: true
  end

  create_table "billing_invoices", force: :cascade do |t|
    t.integer "author_id", null: false
    t.string "reference", null: false
    t.datetime "settled_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "subscriber_id"
    t.integer "subscription_id"
    t.datetime "due_at"
    t.string "currency", default: "USD", null: false
    t.index ["author_id"], name: "index_billing_invoices_on_author_id"
    t.index ["reference"], name: "index_billing_invoices_on_reference", unique: true
    t.index ["subscriber_id"], name: "index_billing_invoices_on_subscriber_id"
    t.index ["subscription_id"], name: "index_billing_invoices_on_subscription_id"
  end

  create_table "billing_line_items", force: :cascade do |t|
    t.integer "invoice_id", null: false
    t.string "description", null: false
    t.integer "amount_cents", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id"], name: "index_billing_line_items_on_invoice_id"
  end

  create_table "billing_payments", force: :cascade do |t|
    t.integer "invoice_id", null: false
    t.string "type", null: false
    t.string "state", default: "pending", null: false
    t.integer "amount_cents", default: 0, null: false
    t.string "last_four"
    t.string "sort_code"
    t.datetime "audited_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "idempotency_key"
    t.index ["idempotency_key"], name: "index_billing_payments_on_idempotency_key", unique: true
    t.index ["invoice_id"], name: "index_billing_payments_on_invoice_id"
  end

  create_table "billing_plans", force: :cascade do |t|
    t.integer "publication_id", null: false
    t.string "name", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "USD", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["publication_id"], name: "index_billing_plans_on_publication_id"
  end

  create_table "billing_refunds", force: :cascade do |t|
    t.integer "payment_id", null: false
    t.integer "amount_cents", null: false
    t.string "reason", null: false
    t.string "idempotency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_billing_refunds_on_idempotency_key", unique: true
    t.index ["payment_id"], name: "index_billing_refunds_on_payment_id"
  end

  create_table "billing_subscription_changes", force: :cascade do |t|
    t.integer "subscription_id", null: false
    t.string "event", null: false
    t.json "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subscription_id"], name: "index_billing_subscription_changes_on_subscription_id"
  end

  create_table "billing_subscriptions", force: :cascade do |t|
    t.integer "subscriber_id", null: false
    t.integer "plan_id", null: false
    t.string "state", default: "active", null: false
    t.datetime "renews_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["plan_id"], name: "index_billing_subscriptions_on_plan_id"
    t.index ["subscriber_id", "plan_id"], name: "index_billing_subscriptions_on_subscriber_id_and_plan_id", unique: true
    t.index ["subscriber_id"], name: "index_billing_subscriptions_on_subscriber_id"
  end

  create_table "collection_articles", force: :cascade do |t|
    t.integer "collection_id", null: false
    t.integer "article_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_collection_articles_on_article_id"
    t.index ["collection_id", "article_id"], name: "index_collection_articles_on_collection_id_and_article_id", unique: true
    t.index ["collection_id"], name: "index_collection_articles_on_collection_id"
  end

  create_table "collections", force: :cascade do |t|
    t.integer "publication_id", null: false
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["publication_id"], name: "index_collections_on_publication_id"
  end

  create_table "comments", force: :cascade do |t|
    t.integer "article_id", null: false
    t.integer "author_id"
    t.text "body", null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "parent_id"
    t.index ["article_id"], name: "index_comments_on_article_id"
    t.index ["author_id"], name: "index_comments_on_author_id"
    t.index ["parent_id"], name: "index_comments_on_parent_id"
  end

  create_table "engagement_events", force: :cascade do |t|
    t.integer "subscriber_id", null: false
    t.integer "article_id", null: false
    t.integer "delivery_id"
    t.string "kind", null: false
    t.json "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_engagement_events_on_article_id"
    t.index ["delivery_id"], name: "index_engagement_events_on_delivery_id"
    t.index ["subscriber_id"], name: "index_engagement_events_on_subscriber_id"
  end

  create_table "gen_hubs", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "gen_records", force: :cascade do |t|
    t.integer "hub_id"
    t.string "name", null: false
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hub_id"], name: "index_gen_records_on_hub_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "author_id", null: false
    t.string "role", default: "author", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_memberships_on_author_id"
    t.index ["organization_id", "author_id"], name: "index_memberships_on_organization_id_and_author_id", unique: true
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
  end

  create_table "newsletter_campaigns", force: :cascade do |t|
    t.integer "publication_id", null: false
    t.integer "article_id", null: false
    t.string "subject", null: false
    t.string "state", default: "draft", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id"], name: "index_newsletter_campaigns_on_article_id"
    t.index ["publication_id"], name: "index_newsletter_campaigns_on_publication_id"
  end

  create_table "newsletter_deliveries", force: :cascade do |t|
    t.integer "campaign_id", null: false
    t.integer "subscriber_id", null: false
    t.string "state", default: "queued", null: false
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["campaign_id", "subscriber_id"], name: "index_newsletter_deliveries_on_campaign_id_and_subscriber_id", unique: true
    t.index ["campaign_id"], name: "index_newsletter_deliveries_on_campaign_id"
    t.index ["subscriber_id"], name: "index_newsletter_deliveries_on_subscriber_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "payouts_agency_profiles", force: :cascade do |t|
    t.string "name", null: false
    t.string "contact_email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "payouts_earnings", force: :cascade do |t|
    t.integer "payee_id", null: false
    t.string "source_type", null: false
    t.integer "source_id", null: false
    t.integer "kind", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "USD", null: false
    t.date "earned_on", null: false
    t.integer "statement_id"
    t.string "description", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payee_id", "source_type", "source_id", "kind"], name: "index_payouts_earnings_on_source_identity", unique: true
    t.index ["payee_id"], name: "index_payouts_earnings_on_payee_id"
    t.index ["statement_id"], name: "index_payouts_earnings_on_statement_id"
  end

  create_table "payouts_individual_profiles", force: :cascade do |t|
    t.integer "author_id", null: false
    t.string "legal_name", null: false
    t.string "tax_id"
    t.json "bank_details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_payouts_individual_profiles_on_author_id"
  end

  create_table "payouts_payees", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "profile_type", null: false
    t.integer "profile_id", null: false
    t.string "display_name", null: false
    t.integer "status", default: 0, null: false
    t.string "payout_method", default: "bank", null: false
    t.string "country_code", default: "US", null: false
    t.string "currency", default: "USD", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_payouts_payees_on_organization_id"
    t.index ["profile_type", "profile_id"], name: "index_payouts_payees_on_profile_type_and_profile_id", unique: true
  end

  create_table "payouts_payout_runs", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.date "period_start", null: false
    t.integer "status", default: 0, null: false
    t.integer "statements_count", default: 0, null: false
    t.integer "started_by_id", null: false
    t.datetime "finalized_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "period_start"], name: "index_payouts_payout_runs_on_organization_id_and_period_start", unique: true
    t.index ["organization_id"], name: "index_payouts_payout_runs_on_organization_id"
    t.index ["started_by_id"], name: "index_payouts_payout_runs_on_started_by_id"
  end

  create_table "payouts_rate_cards", force: :cascade do |t|
    t.integer "publication_id", null: false
    t.integer "basis", null: false
    t.json "terms", default: {}, null: false
    t.date "effective_on", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["publication_id", "effective_on"], name: "index_payouts_rate_cards_on_publication_id_and_effective_on", unique: true
    t.index ["publication_id"], name: "index_payouts_rate_cards_on_publication_id"
  end

  create_table "payouts_representations", force: :cascade do |t|
    t.integer "agency_profile_id", null: false
    t.integer "author_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agency_profile_id", "author_id"], name: "idx_on_agency_profile_id_author_id_1270a0dc55", unique: true
    t.index ["agency_profile_id"], name: "index_payouts_representations_on_agency_profile_id"
    t.index ["author_id"], name: "index_payouts_representations_on_author_id"
  end

  create_table "payouts_statements", force: :cascade do |t|
    t.integer "payout_run_id", null: false
    t.integer "payee_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.string "currency", default: "USD", null: false
    t.string "hold_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["payee_id"], name: "index_payouts_statements_on_payee_id"
    t.index ["payout_run_id", "payee_id"], name: "index_payouts_statements_on_payout_run_id_and_payee_id", unique: true
    t.index ["payout_run_id"], name: "index_payouts_statements_on_payout_run_id"
  end

  create_table "payouts_transfers", force: :cascade do |t|
    t.string "type", null: false
    t.integer "statement_id", null: false
    t.string "state", null: false
    t.integer "amount_cents", null: false
    t.string "currency", default: "USD", null: false
    t.string "idempotency_key", null: false
    t.integer "attempts", default: 0, null: false
    t.string "provider_reference"
    t.string "last_error"
    t.json "destination", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["idempotency_key"], name: "index_payouts_transfers_on_idempotency_key", unique: true
    t.index ["statement_id"], name: "index_payouts_transfers_on_statement_id", unique: true
  end

  create_table "publications", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_publications_on_organization_id"
    t.index ["slug"], name: "index_publications_on_slug", unique: true
  end

  create_table "review_assignments", force: :cascade do |t|
    t.integer "article_revision_id", null: false
    t.integer "reviewer_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_revision_id", "reviewer_id"], name: "idx_on_article_revision_id_reviewer_id_fecb738717", unique: true
    t.index ["article_revision_id"], name: "index_review_assignments_on_article_revision_id"
    t.index ["reviewer_id"], name: "index_review_assignments_on_reviewer_id"
  end

  create_table "review_decisions", force: :cascade do |t|
    t.integer "review_assignment_id", null: false
    t.string "outcome", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["review_assignment_id"], name: "index_review_decisions_on_review_assignment_id", unique: true
  end

  create_table "subscribers", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "author_id"
    t.string "name", null: false
    t.string "email", null: false
    t.json "preferences", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_subscribers_on_author_id"
    t.index ["organization_id", "email"], name: "index_subscribers_on_organization_id_and_email", unique: true
    t.index ["organization_id"], name: "index_subscribers_on_organization_id"
  end

  create_table "support_ticket_messages", force: :cascade do |t|
    t.integer "ticket_id", null: false
    t.integer "author_id"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_support_ticket_messages_on_author_id"
    t.index ["ticket_id"], name: "index_support_ticket_messages_on_ticket_id"
  end

  create_table "support_tickets", force: :cascade do |t|
    t.integer "subscriber_id", null: false
    t.integer "assignee_id"
    t.string "subject_type"
    t.integer "subject_id"
    t.string "title", null: false
    t.string "state", default: "open", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assignee_id"], name: "index_support_tickets_on_assignee_id"
    t.index ["subject_type", "subject_id"], name: "index_support_tickets_on_subject"
    t.index ["subscriber_id"], name: "index_support_tickets_on_subscriber_id"
  end

  create_table "syndication_licenses", force: :cascade do |t|
    t.integer "partner_id", null: false
    t.integer "article_id", null: false
    t.integer "granted_by_id", null: false
    t.string "territory", null: false
    t.date "starts_on", null: false
    t.date "ends_on", null: false
    t.boolean "exclusive", default: false, null: false
    t.integer "fee_cents", null: false
    t.string "currency", default: "USD", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["article_id", "territory"], name: "index_syndication_licenses_on_article_id_and_territory"
    t.index ["article_id"], name: "index_syndication_licenses_on_article_id"
    t.index ["granted_by_id"], name: "index_syndication_licenses_on_granted_by_id"
    t.index ["partner_id"], name: "index_syndication_licenses_on_partner_id"
  end

  create_table "syndication_partners", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "name", null: false
    t.string "contact_email", null: false
    t.string "api_token", null: false
    t.string "webhook_secret"
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_syndication_partners_on_api_token", unique: true
    t.index ["organization_id"], name: "index_syndication_partners_on_organization_id"
  end

  create_table "syndication_usage_reports", force: :cascade do |t|
    t.integer "license_id", null: false
    t.date "period_start", null: false
    t.integer "pickups", default: 0, null: false
    t.integer "impressions", default: 0, null: false
    t.datetime "reported_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["license_id", "period_start"], name: "index_syndication_usage_reports_on_license_id_and_period_start", unique: true
    t.index ["license_id"], name: "index_syndication_usage_reports_on_license_id"
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.integer "webhook_endpoint_id", null: false
    t.integer "activity_event_id", null: false
    t.string "state", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.json "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_event_id"], name: "index_webhook_deliveries_on_activity_event_id"
    t.index ["webhook_endpoint_id", "activity_event_id"], name: "idx_on_webhook_endpoint_id_activity_event_id_d10c51c218", unique: true
    t.index ["webhook_endpoint_id"], name: "index_webhook_deliveries_on_webhook_endpoint_id"
  end

  create_table "webhook_endpoints", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.string "url", null: false
    t.string "secret", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_webhook_endpoints_on_organization_id"
  end

  add_foreign_key "activity_events", "authors", column: "actor_id"
  add_foreign_key "activity_events", "organizations"
  add_foreign_key "article_revisions", "articles"
  add_foreign_key "article_revisions", "authors"
  add_foreign_key "article_tags", "articles"
  add_foreign_key "article_tags", "tags"
  add_foreign_key "articles", "authors"
  add_foreign_key "articles", "publications"
  add_foreign_key "billing_invoices", "authors"
  add_foreign_key "billing_invoices", "billing_subscriptions", column: "subscription_id"
  add_foreign_key "billing_invoices", "subscribers"
  add_foreign_key "billing_line_items", "billing_invoices", column: "invoice_id"
  add_foreign_key "billing_payments", "billing_invoices", column: "invoice_id"
  add_foreign_key "billing_plans", "publications"
  add_foreign_key "billing_refunds", "billing_payments", column: "payment_id"
  add_foreign_key "billing_subscription_changes", "billing_subscriptions", column: "subscription_id"
  add_foreign_key "billing_subscriptions", "billing_plans", column: "plan_id"
  add_foreign_key "billing_subscriptions", "subscribers"
  add_foreign_key "collection_articles", "articles"
  add_foreign_key "collection_articles", "collections"
  add_foreign_key "collections", "publications"
  add_foreign_key "comments", "articles"
  add_foreign_key "comments", "authors"
  add_foreign_key "comments", "comments", column: "parent_id"
  add_foreign_key "engagement_events", "articles"
  add_foreign_key "engagement_events", "newsletter_deliveries", column: "delivery_id"
  add_foreign_key "engagement_events", "subscribers"
  add_foreign_key "memberships", "authors"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "newsletter_campaigns", "articles"
  add_foreign_key "newsletter_campaigns", "publications"
  add_foreign_key "newsletter_deliveries", "newsletter_campaigns", column: "campaign_id"
  add_foreign_key "newsletter_deliveries", "subscribers"
  add_foreign_key "payouts_earnings", "payouts_payees", column: "payee_id"
  add_foreign_key "payouts_earnings", "payouts_statements", column: "statement_id"
  add_foreign_key "payouts_individual_profiles", "authors"
  add_foreign_key "payouts_payees", "organizations"
  add_foreign_key "payouts_payout_runs", "authors", column: "started_by_id"
  add_foreign_key "payouts_payout_runs", "organizations"
  add_foreign_key "payouts_rate_cards", "publications"
  add_foreign_key "payouts_representations", "authors"
  add_foreign_key "payouts_representations", "payouts_agency_profiles", column: "agency_profile_id"
  add_foreign_key "payouts_statements", "payouts_payees", column: "payee_id"
  add_foreign_key "payouts_statements", "payouts_payout_runs", column: "payout_run_id"
  add_foreign_key "payouts_transfers", "payouts_statements", column: "statement_id"
  add_foreign_key "publications", "organizations"
  add_foreign_key "review_assignments", "article_revisions"
  add_foreign_key "review_assignments", "authors", column: "reviewer_id"
  add_foreign_key "review_decisions", "review_assignments"
  add_foreign_key "subscribers", "authors"
  add_foreign_key "subscribers", "organizations"
  add_foreign_key "support_ticket_messages", "authors"
  add_foreign_key "support_ticket_messages", "support_tickets", column: "ticket_id"
  add_foreign_key "support_tickets", "authors", column: "assignee_id"
  add_foreign_key "support_tickets", "subscribers"
  add_foreign_key "syndication_licenses", "articles"
  add_foreign_key "syndication_licenses", "authors", column: "granted_by_id"
  add_foreign_key "syndication_licenses", "syndication_partners", column: "partner_id"
  add_foreign_key "syndication_partners", "organizations"
  add_foreign_key "syndication_usage_reports", "syndication_licenses", column: "license_id"
  add_foreign_key "webhook_deliveries", "activity_events"
  add_foreign_key "webhook_deliveries", "webhook_endpoints"
  add_foreign_key "webhook_endpoints", "organizations"
end
