class CreateBillingTables < ActiveRecord::Migration[8.0]
  def change
    create_table :billing_invoices do |t|
      t.references :author, null: false, foreign_key: true
      t.string :reference, null: false, index: { unique: true }
      t.datetime :settled_at
      t.datetime :archived_at
      t.timestamps
    end

    create_table :billing_line_items do |t|
      t.references :invoice, null: false, foreign_key: { to_table: :billing_invoices }
      t.string :description, null: false
      t.integer :amount_cents, null: false, default: 0
      t.timestamps
    end

    # STI: `type` discriminates CardPayment / BankPayment.
    create_table :billing_payments do |t|
      t.references :invoice, null: false, foreign_key: { to_table: :billing_invoices }
      t.string :type, null: false
      t.string :state, null: false, default: "pending"
      t.integer :amount_cents, null: false, default: 0
      t.string :last_four
      t.string :sort_code
      t.datetime :audited_at
      t.timestamps
    end
  end
end
