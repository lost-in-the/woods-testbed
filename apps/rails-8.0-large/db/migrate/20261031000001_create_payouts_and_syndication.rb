class CreatePayoutsAndSyndication < ActiveRecord::Migration[8.0]
  def change
    create_table :payouts_payees do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :profile_type, null: false
      t.integer :profile_id, null: false
      t.string :display_name, null: false
      t.integer :status, default: 0, null: false
      t.string :payout_method, default: 'bank', null: false
      t.string :country_code, default: 'US', null: false
      t.string :currency, default: 'USD', null: false
      t.timestamps
    end
    add_index :payouts_payees, [:profile_type, :profile_id], unique: true
    create_table :payouts_individual_profiles do |t|
      t.references :author, null: false, foreign_key: true
      t.string :legal_name, null: false
      t.string :tax_id
      t.json :bank_details, default: {}, null: false
      t.timestamps
    end
    create_table :payouts_agency_profiles do |t|
      t.string :name, null: false
      t.string :contact_email, null: false
      t.timestamps
    end
    create_table :payouts_representations do |t|
      t.references :agency_profile, null: false, foreign_key: { to_table: :payouts_agency_profiles }
      t.references :author, null: false, foreign_key: true
      t.timestamps
    end
    add_index :payouts_representations, [:agency_profile_id, :author_id], unique: true
    create_table :payouts_rate_cards do |t|
      t.references :publication, null: false, foreign_key: true
      t.integer :basis, null: false
      t.json :terms, default: {}, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :payouts_rate_cards, [:publication_id, :effective_on], unique: true
    create_table :payouts_payout_runs do |t|
      t.references :organization, null: false, foreign_key: true
      t.date :period_start, null: false
      t.integer :status, default: 0, null: false
      t.integer :statements_count, default: 0, null: false
      t.references :started_by, null: false, foreign_key: { to_table: :authors }
      t.datetime :finalized_at
      t.timestamps
    end
    add_index :payouts_payout_runs, [:organization_id, :period_start], unique: true
    create_table :payouts_statements do |t|
      t.references :payout_run, null: false, foreign_key: { to_table: :payouts_payout_runs }
      t.references :payee, null: false, foreign_key: { to_table: :payouts_payees }
      t.integer :status, default: 0, null: false
      t.integer :total_cents, default: 0, null: false
      t.string :currency, default: 'USD', null: false
      t.string :hold_reason
      t.timestamps
    end
    add_index :payouts_statements, [:payout_run_id, :payee_id], unique: true
    create_table :payouts_earnings do |t|
      t.references :payee, null: false, foreign_key: { to_table: :payouts_payees }
      t.string :source_type, null: false
      t.integer :source_id, null: false
      t.integer :kind, null: false
      t.integer :amount_cents, null: false
      t.string :currency, default: 'USD', null: false
      t.date :earned_on, null: false
      t.references :statement, foreign_key: { to_table: :payouts_statements }
      t.string :description, null: false
      t.timestamps
    end
    add_index :payouts_earnings, [:payee_id, :source_type, :source_id, :kind], unique: true, name: 'index_payouts_earnings_on_source_identity'
    create_table :payouts_transfers do |t|
      t.string :type, null: false
      t.references :statement, null: false, foreign_key: { to_table: :payouts_statements }, index: { unique: true }
      t.string :state, null: false
      t.integer :amount_cents, null: false
      t.string :currency, default: 'USD', null: false
      t.string :idempotency_key, null: false, index: { unique: true }
      t.integer :attempts, default: 0, null: false
      t.string :provider_reference
      t.string :last_error
      t.json :destination, default: {}, null: false
      t.timestamps
    end
    create_table :syndication_partners do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :contact_email, null: false
      t.string :api_token, null: false, index: { unique: true }
      t.string :webhook_secret
      t.integer :status, default: 0, null: false
      t.timestamps
    end
    create_table :syndication_licenses do |t|
      t.references :partner, null: false, foreign_key: { to_table: :syndication_partners }
      t.references :article, null: false, foreign_key: true
      t.references :granted_by, null: false, foreign_key: { to_table: :authors }
      t.string :territory, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.boolean :exclusive, default: false, null: false
      t.integer :fee_cents, null: false
      t.string :currency, default: 'USD', null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :syndication_licenses, [:article_id, :territory]
    create_table :syndication_usage_reports do |t|
      t.references :license, null: false, foreign_key: { to_table: :syndication_licenses }
      t.date :period_start, null: false
      t.integer :pickups, default: 0, null: false
      t.integer :impressions, default: 0, null: false
      t.datetime :reported_at, null: false
      t.timestamps
    end
    add_index :syndication_usage_reports, [:license_id, :period_start], unique: true
  end
end
