class CreateCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :credentials do |t|
      t.string :provider
      t.string :key_type
      t.text :value
      t.text :notes
      t.text :metadata

      t.timestamps
    end
  end
end
