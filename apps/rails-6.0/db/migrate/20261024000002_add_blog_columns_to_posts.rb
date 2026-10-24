# Blog scenario (woods-testbed#38): the slug Post sets before save and its author.
class AddBlogColumnsToPosts < ActiveRecord::Migration[6.0]
  def change
    add_column :posts, :slug, :string
    add_index :posts, :slug, unique: true
    add_reference :posts, :author, foreign_key: { to_table: :users }
  end
end
