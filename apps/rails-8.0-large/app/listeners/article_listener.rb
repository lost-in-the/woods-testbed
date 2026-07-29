# Event subscriber. EventExtractor's two-pass scan pairs this with the
# instrument call in PublishArticle to build one `event` unit carrying both
# publishers and subscribers.
class ArticleListener
  def self.subscribe!
    ActiveSupport::Notifications.subscribe("article.published") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      Rails.logger.info("[ArticleListener] article #{event.payload[:article_id]} published")
    end
  end
end
