class AddArticleCommentCounts < ActiveRecord::Migration[8.0]
  def up
    add_column :articles, :comments_count, :integer, default: 0, null: false
    execute 'UPDATE articles SET comments_count = (SELECT COUNT(*) FROM comments WHERE comments.article_id = articles.id)'
    add_check_constraint :articles, 'comments_count >= 0', name: 'articles_comment_count_nonnegative'
  end
  def down
    remove_check_constraint :articles, name: 'articles_comment_count_nonnegative'
    remove_column :articles, :comments_count
  end
end
