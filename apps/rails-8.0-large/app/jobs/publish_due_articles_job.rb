class PublishDueArticlesJob < ApplicationJob
  queue_as :editorial
  def perform
    Article.where(state: 'scheduled').where('scheduled_at <= ?', Time.current).find_each do |article|
      editor = article.publication.organization.memberships.find_by!(role: 'editor').author
      PublishArticle.new(author: editor).call(article)
    end
  end
end
