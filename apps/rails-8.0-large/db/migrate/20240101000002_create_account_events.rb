class CreateAccountEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :account_events do |t|
      t.references :account, null: false, foreign_key: true
      t.string :kind, null: false
      t.timestamps
    end
  end
end
