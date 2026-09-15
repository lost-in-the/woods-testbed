class CreateCanopy < ActiveRecord::Migration[8.0]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.timestamps
    end
    create_table :publications do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.timestamps
    end
    create_table :memberships do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: true
      t.string :role, default: 'author', null: false
      t.timestamps
    end
    add_index :memberships, [:organization_id, :author_id], unique: true
    # Backfill using SQL so this migration does not depend on future model code.
    execute "INSERT INTO organizations (name, slug, created_at, updated_at) VALUES ('Canopy Press', 'canopy', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    execute "INSERT INTO publications (organization_id, name, slug, created_at, updated_at) SELECT id, 'Field Notes', 'field-notes', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM organizations WHERE slug = 'canopy'"
    execute "INSERT INTO memberships (organization_id, author_id, role, created_at, updated_at) SELECT organizations.id, authors.id, 'editor', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM organizations CROSS JOIN authors WHERE organizations.slug = 'canopy'"
    add_reference :articles, :publication, foreign_key: true
    execute "UPDATE articles SET publication_id = (SELECT id FROM publications WHERE slug = 'field-notes')"
    change_column_null :articles, :publication_id, false
    add_column :articles, :state, :string, default: 'draft', null: false
    execute "UPDATE articles SET state = 'published' WHERE published_at IS NOT NULL"
    add_column :articles, :scheduled_at, :datetime
    add_column :articles, :lock_version, :integer, default: 0, null: false
    add_index :articles, [:publication_id, :state, :scheduled_at]
    add_reference :comments, :parent, foreign_key: { to_table: :comments }
    add_index :article_tags, [:article_id, :tag_id], unique: true
    create_table :article_revisions do |t|
      t.references :article, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: true
      t.integer :number, null: false
      t.string :title, null: false
      t.text :body
      t.timestamps
    end
    add_index :article_revisions, [:article_id, :number], unique: true
    create_table :review_assignments do |t|
      t.references :article_revision, null: false, foreign_key: true
      t.references :reviewer, null: false, foreign_key: { to_table: :authors }
      t.timestamps
    end
    add_index :review_assignments, [:article_revision_id, :reviewer_id], unique: true
    create_table :review_decisions do |t|
      t.references :review_assignment, null: false, foreign_key: true, index: { unique: true }
      t.string :outcome, null: false
      t.text :notes
      t.timestamps
    end
    create_table :collections do |t|
      t.references :publication, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end
    create_table :collection_articles do |t|
      t.references :collection, null: false, foreign_key: true
      t.references :article, null: false, foreign_key: true
      t.integer :position, default: 0, null: false
      t.timestamps
    end
    add_index :collection_articles, [:collection_id, :article_id], unique: true
    create_table :subscribers do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :author, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false
      t.json :preferences, default: {}, null: false
      t.timestamps
    end
    add_index :subscribers, [:organization_id, :email], unique: true
    create_table :billing_plans do |t|
      t.references :publication, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :amount_cents, null: false
      t.string :currency, default: 'USD', null: false
      t.timestamps
    end
    create_table :billing_subscriptions do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.references :plan, null: false, foreign_key: { to_table: :billing_plans }
      t.string :state, default: 'active', null: false
      t.datetime :renews_at, null: false
      t.timestamps
    end
    add_index :billing_subscriptions, [:subscriber_id, :plan_id], unique: true
    create_table :billing_subscription_changes do |t|
      t.references :subscription, null: false, foreign_key: { to_table: :billing_subscriptions }
      t.string :event, null: false
      t.json :details, default: {}, null: false
      t.timestamps
    end
    add_reference :billing_invoices, :subscriber, foreign_key: true
    add_reference :billing_invoices, :subscription, foreign_key: { to_table: :billing_subscriptions }
    add_column :billing_invoices, :due_at, :datetime
    add_column :billing_invoices, :currency, :string, default: 'USD', null: false
    add_column :billing_payments, :idempotency_key, :string
    add_index :billing_payments, :idempotency_key, unique: true
    create_table :billing_refunds do |t|
      t.references :payment, null: false, foreign_key: { to_table: :billing_payments }
      t.integer :amount_cents, null: false
      t.string :reason, null: false
      t.string :idempotency_key, null: false, index: { unique: true }
      t.timestamps
    end
    create_table :newsletter_campaigns do |t|
      t.references :publication, null: false, foreign_key: true
      t.references :article, null: false, foreign_key: true
      t.string :subject, null: false
      t.string :state, default: 'draft', null: false
      t.timestamps
    end
    create_table :newsletter_deliveries do |t|
      t.references :campaign, null: false, foreign_key: { to_table: :newsletter_campaigns }
      t.references :subscriber, null: false, foreign_key: true
      t.string :state, default: 'queued', null: false
      t.datetime :delivered_at
      t.timestamps
    end
    add_index :newsletter_deliveries, [:campaign_id, :subscriber_id], unique: true
    create_table :engagement_events do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.references :article, null: false, foreign_key: true
      t.references :delivery, foreign_key: { to_table: :newsletter_deliveries }
      t.string :kind, null: false
      t.json :metadata, default: {}, null: false
      t.timestamps
    end
    create_table :support_tickets do |t|
      t.references :subscriber, null: false, foreign_key: true
      t.references :assignee, foreign_key: { to_table: :authors }
      t.references :subject, polymorphic: true
      t.string :title, null: false
      t.string :state, default: 'open', null: false
      t.timestamps
    end
    create_table :support_ticket_messages do |t|
      t.references :ticket, null: false, foreign_key: { to_table: :support_tickets }
      t.references :author, foreign_key: true
      t.text :body, null: false
      t.timestamps
    end
    create_table :activity_events do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :actor, foreign_key: { to_table: :authors }
      t.references :subject, polymorphic: true, null: false
      t.string :action, null: false
      t.json :metadata, default: {}, null: false
      t.timestamps
    end
    create_table :webhook_endpoints do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :url, null: false
      t.string :secret, null: false
      t.timestamps
    end
    create_table :webhook_deliveries do |t|
      t.references :webhook_endpoint, null: false, foreign_key: true
      t.references :activity_event, null: false, foreign_key: true
      t.string :state, default: 'pending', null: false
      t.integer :attempts, default: 0, null: false
      t.json :payload, default: {}, null: false
      t.timestamps
    end
    add_index :webhook_deliveries, [:webhook_endpoint_id, :activity_event_id], unique: true
  end
end
