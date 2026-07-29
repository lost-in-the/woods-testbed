# Service unit from a NON-STANDARD directory: app/use_cases is one of
# ServiceExtractor's five directories and the one a real host app is least
# likely to have. #2 asks for exactly this.
#
# Also the event publisher — ActiveSupport::Notifications.instrument is what
# EventExtractor treats as a publish.
class PublishArticle
  def initialize(author:)
    @author = author
  end

  def call(attributes)
    article = @author.articles.create!(attributes.merge(published_at: Time.current))

    ActiveSupport::Notifications.instrument("article.published", article_id: article.id)
    PublishArticleJob.perform_later(article.id)

    article
  end
end
