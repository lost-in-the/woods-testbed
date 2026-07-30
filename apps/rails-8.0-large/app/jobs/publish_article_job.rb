class PublishArticleJob < ApplicationJob
  queue_as :default

  def perform(article_id)
    article = Article.find(article_id)
    AuthorMailer.article_published(article).deliver_later
  end
end
