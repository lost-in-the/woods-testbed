class CreatePosts < ActiveRecord::Migration[8.0]
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.string :slug
      t.text :body
      t.string :state, null: false, default: "draft"
      t.datetime :published_at
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.integer :comments_count, null: false, default: 0
      t.timestamps
    end
    add_index :posts, :slug, unique: true
    add_index :posts, :state
  end
end
