class PayoutsListener
  def self.subscribe!
    return if @subscriber
    @subscriber = ActiveSupport::Notifications.subscribe('article.published') do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      begin
        Payouts::AccrueArticleEarning.new.call(Article.find(event.payload[:article_id]))
      rescue StandardError => e
        # The article is already published; a payouts failure must not undo
        # the rest of publishing. Accrual is idempotent, so it can be redone.
        Rails.error.report(e, handled: true, context: { article_id: event.payload[:article_id] })
      end
    end
  end
end
