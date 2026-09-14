class PublishArticle
  def initialize(author:)
    @author = author
  end

  def call(article)
    EditorialWorkflow.new(author: @author).authorize!(article, :publish?)
    changed = false
    article.with_lock do
      return article if article.state == 'published'
      unless %w[approved scheduled].include?(article.state) && (article.scheduled_at.nil? || article.scheduled_at <= Time.current)
        raise EditorialWorkflow::InvalidTransition, 'Article must be approved and due for publication'
      end
      revision = article.latest_revision
      unless revision&.review_assignments&.joins(:review_decision)&.where(review_decisions: { outcome: 'approved' })&.exists?
        raise EditorialWorkflow::InvalidTransition, 'The latest revision has no approval'
      end
      article.update!(title: revision.title, body: revision.body, state: 'published', published_at: Time.current)
      RecordActivity.new.call(organization: article.publication.organization, actor: @author, subject: article, action: 'article.published')
      changed = true
    end
    if changed
      Rails.cache.delete("articles/published/#{article.publication_id}")
      ActiveSupport::Notifications.instrument('article.published', article_id: article.id)
      PublishArticleJob.perform_later(article.id)
    end
    article
  end
end
