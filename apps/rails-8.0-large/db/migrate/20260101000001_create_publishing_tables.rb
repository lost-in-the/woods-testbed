class CreatePublishingTables < ActiveRecord::Migration[8.0]
  def change
    create_table :authors do |t|
      t.string :name, null: false
      t.string :email, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :articles do |t|
      t.references :author, null: false, foreign_key: true
      t.string :title, null: false
      t.string :slug, null: false, index: { unique: true }
      t.text :body
      t.datetime :published_at
      t.datetime :archived_at
      t.timestamps
    end

    create_table :comments do |t|
      t.references :article, null: false, foreign_key: true
      t.references :author, foreign_key: true
      t.text :body, null: false
      t.datetime :archived_at
      t.timestamps
    end

    create_table :tags do |t|
      t.string :name, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :article_tags do |t|
      t.references :article, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end
  end
end
