# ActionCableExtractor discovers channels from ActionCable::Channel::Base
# descendants at runtime, which is why action_cable/engine is required in
# config/application.rb.
class ArticleCommentsChannel < ApplicationCable::Channel
  def subscribed
    article = Article.find(params[:article_id])
    stream_for article
  end

  def unsubscribed
    stop_all_streams
  end
end
