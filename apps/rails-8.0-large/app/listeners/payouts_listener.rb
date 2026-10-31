class PayoutsListener
  def self.subscribe!
    return if @subscriber
    @subscriber = ActiveSupport::Notifications.subscribe('article.published') do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      Payouts::AccrueArticleEarning.new.call(Article.find(event.payload[:article_id]))
    end
  end
end
